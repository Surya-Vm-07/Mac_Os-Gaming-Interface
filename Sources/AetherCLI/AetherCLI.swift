import AetherCore
import Dispatch
import Foundation

/// Phase 1 proof-of-concept CLI. It exercises the engine core without any UI.
///
///   aether hw
///   aether profiles
///   aether route <profile-id> [--native-app PATH] [--exe PATH] [--prefer-local]
///   aether launch --wine PATH --d3dmetal DIR --exe PATH
///                 [--wineserver PATH] [--bottle DIR] [--profile ID] [--no-hud] [-- GAME_ARGS...]
@main
struct AetherCLI {
    static func main() async {
        var arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        guard !arguments.isEmpty else {
            printUsage()
            exit(64)
        }
        let command = arguments.removeFirst()

        do {
            switch command {
            case "hw":
                printHardware()
            case "profiles":
                try printProfiles()
            case "route":
                try route(Options(arguments, valued: ["--native-app", "--exe"]))
            case "launch":
                let code = try await launch(
                    Options(arguments, valued: ["--wine", "--wineserver", "--d3dmetal", "--exe", "--bottle", "--profile"])
                )
                exit(code)
            case "-h", "--help", "help":
                printUsage()
            default:
                printError("Unknown command '\(command)'.")
                printUsage()
                exit(64)
            }
        } catch {
            printError(String(describing: error))
            exit(1)
        }
    }

    // MARK: - Commands

    static func printHardware() {
        let hw = MacHardwareProfiler.current
        print("""
        Chip            \(hw.chipName)\(hw.chip.map { "  [\($0)]" } ?? "")
        Apple Silicon   \(hw.isAppleSilicon ? "yes" : "no")\(hw.isRunningUnderRosetta ? "  (WARNING: aether is running under Rosetta)" : "")
        CPU cores       \(hw.performanceCores)P + \(hw.efficiencyCores)E
        GPU cores       \(hw.gpuCoreCount == 0 ? "unknown" : String(hw.gpuCoreCount))
        Unified memory  \(hw.totalMemoryGB) GB
        Thermal         \(MacHardwareProfiler.currentThermalPressure().rawValue)
        Aether tier     \(hw.tier)
        """)
    }

    static func printProfiles() throws {
        let catalog = try GameManifestLoader().load()
        for profile in catalog.allProfiles {
            let ac = profile.hasKernelAnticheat ? "  kernel-AC: \(profile.anticheatName ?? "yes")" : ""
            print("\(profile.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(profile.title)  min-tier \(profile.minLocalTier)\(ac)")
        }
        for issue in catalog.issues { printError("manifest: \(issue)") }
    }

    static func route(_ options: Options) throws {
        guard let id = options.positionals.first else { throw CLIError.missing("<profile-id>") }
        let catalog = try GameManifestLoader().load()
        guard let profile = catalog.profile(id: id) else { throw CLIError.unknownProfile(id) }

        let installation = GameInstallation(
            nativeApplication: options.values["--native-app"].map { URL(filePath: $0) },
            windowsExecutable: options.values["--exe"].map { URL(filePath: $0) }
        )
        let decision = try EngineRouter().route(
            profile: profile,
            installation: installation,
            hardware: MacHardwareProfiler.current,
            preference: options.flags.contains("--prefer-local") ? .preferLocal : .automatic
        )
        print("[\(decision.engine.badgeLabel)] \(profile.title)")
        print("  \(decision.reason)")
        if decision.allowLocalOverride {
            print("  Override available: re-run with --prefer-local for local low-spec.")
        }
    }

    static func launch(_ options: Options) async throws -> Int32 {
        guard let wine = options.values["--wine"] else { throw CLIError.missing("--wine") }
        guard let d3dmetal = options.values["--d3dmetal"] else { throw CLIError.missing("--d3dmetal") }
        guard let exe = options.values["--exe"] else { throw CLIError.missing("--exe") }

        var translation = LocalTranslationConfig()
        var bottleName = "default"
        if let id = options.values["--profile"] {
            guard let profile = try GameManifestLoader().load().profile(id: id) else {
                throw CLIError.unknownProfile(id)
            }
            guard let config = profile.localTranslation else { throw CLIError.noLocalConfig(id) }
            translation = config
            bottleName = id
        }

        let runtime = BottleRuntime(
            wineBinary: URL(filePath: wine),
            wineserverBinary: options.values["--wineserver"].map { URL(filePath: $0) },
            d3dMetalLibraryDirectory: URL(filePath: d3dmetal, directoryHint: .isDirectory)
        )
        let request = BottleLaunchRequest(
            executable: URL(filePath: exe),
            bottle: options.values["--bottle"].map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? AetherPaths.bottle(for: bottleName),
            translation: translation,
            metalHUDEnabled: !options.flags.contains("--no-hud"),
            additionalArguments: options.passthrough
        )

        let engine = BottleEngine(runtime: runtime)
        let events = try await engine.launch(request)

        // Ctrl-C does a clean teardown (SIGTERM → wineserver -k), not an abrupt kill of the CLI.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { @Sendable in
            printError("[AETHER] Ctrl-C: shutting down bottle…")
            Task { await engine.terminate() }
        }
        interrupt.resume()
        defer { interrupt.cancel() }

        var exitCode: Int32 = 0
        for await event in events {
            switch event {
            case .launched(let pid):
                print("[AETHER] Wine started (pid \(pid)). Ctrl-C to stop.")
            case .stdout(let line):
                print(line)
            case .stderr(let line):
                printError(line)
            case .processExited(let ended):
                print("[AETHER] Wine \(ended). Waiting for the bottle to go idle…")
                if let hint = ended.launcherFailureHint { printError("[AETHER HINT] \(hint)") }
                exitCode = ended.reason == .exited ? ended.status : 128 + ended.status
            }
        }
        print("[AETHER] Bottle idle. Session ended.")
        return exitCode
    }

    // MARK: - Output

    static func printUsage() {
        print("""
        usage:
          aether hw
          aether profiles
          aether route <profile-id> [--native-app PATH] [--exe PATH] [--prefer-local]
          aether launch --wine PATH --d3dmetal DIR --exe PATH
                        [--wineserver PATH] [--bottle DIR] [--profile ID] [--no-hud] [-- GAME_ARGS...]
        """)
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

enum CLIError: Error, CustomStringConvertible {
    case missing(String)
    case unknownProfile(String)
    case noLocalConfig(String)

    var description: String {
        switch self {
        case .missing(let what): "Missing required argument \(what)."
        case .unknownProfile(let id): "No profile with id '\(id)'. Run `aether profiles`."
        case .noLocalConfig(let id): "Profile '\(id)' has no local_translation block."
        }
    }
}

/// Minimal parser: `--key value`, `--flag`, positionals, and `--` passthrough. No dependencies.
struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []
    var passthrough: [String] = []

    init(_ arguments: [String], valued: Set<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument == "--" {
                while let rest = iterator.next() { passthrough.append(rest) }
            } else if valued.contains(argument) {
                guard let value = iterator.next() else { throw CLIError.missing("value for \(argument)") }
                values[argument] = value
            } else if argument.hasPrefix("--") {
                flags.insert(argument)
            } else {
                positionals.append(argument)
            }
        }
    }
}
