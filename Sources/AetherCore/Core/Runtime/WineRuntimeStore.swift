import Foundation

/// Which graphics stack a runtime carries. Matches the setup wizard's `runtime.json` (`flavor`).
public enum RuntimeFlavor: String, Codable, Sendable, Hashable {
    /// Plain Wine: WineD3D and DXVK games run here.
    case base
    /// Base + Apple GPTK `D3DMetal.framework` (APFS clone).
    case d3dmetal
    /// Base + DXMT modules (APFS clone).
    case dxmt

    public static func forBackend(_ backend: TranslationBackend) -> RuntimeFlavor {
        switch backend {
        case .d3dmetal: .d3dmetal
        case .dxmt: .dxmt
        case .dxvk, .wined3d: .base
        }
    }
}

/// An installed Wine runtime, decoded from `<engineRoot>/runtimes/<id>/runtime.json`.
public struct WineRuntime: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let flavor: RuntimeFlavor
    public let baseId: String?
    /// Directory containing `bin/wine`, relative to `directory`.
    public let wineRoot: String
    public let installedAt: Int64
    /// The runtime's folder. Set by the store after decoding; not part of the manifest.
    public var directory = URL(filePath: "/")

    enum CodingKeys: String, CodingKey {
        case id, name, version, flavor, baseId, wineRoot, installedAt
    }

    public init(id: String, name: String, version: String, flavor: RuntimeFlavor, baseId: String?, wineRoot: String, installedAt: Int64, directory: URL) {
        self.id = id
        self.name = name
        self.version = version
        self.flavor = flavor
        self.baseId = baseId
        self.wineRoot = wineRoot
        self.installedAt = installedAt
        self.directory = directory
    }

    public var wineRootURL: URL {
        directory.appending(path: wineRoot, directoryHint: .isDirectory)
    }

    /// Older builds ship `wine64`; new-WoW64 builds (Wine 9+) ship a single `wine`.
    public var wineBinary: URL {
        let bin = wineRootURL.appending(path: "bin", directoryHint: .isDirectory)
        let wine64 = bin.appending(path: "wine64")
        return FileManager.default.isExecutableFile(atPath: wine64.path(percentEncoded: false)) ? wine64 : bin.appending(path: "wine")
    }

    public var wineserver: URL {
        wineRootURL.appending(path: "bin/wineserver")
    }

    public var libDirectory: URL {
        wineRootURL.appending(path: "lib", directoryHint: .isDirectory)
    }
}

public enum WineRuntimeError: Error, Equatable, CustomStringConvertible {
    case noRuntime
    case backendNotInstalled(TranslationBackend)
    case dxvkNotInstalled
    case prefixInitFailed(Int32)

    public var description: String {
        switch self {
        case .noRuntime:
            "No Wine runtime installed. Run the setup wizard (Aether Launcher) to download the free Wine Staging build."
        case .backendNotInstalled(let backend):
            "\(backend.label) is not installed for your Wine runtime. Install it in the setup wizard, or pick another preset."
        case .dxvkNotInstalled:
            "DXVK is not installed. Download it in the setup wizard, or pick another preset."
        case .prefixInitFailed(let status):
            "Creating the Windows bottle failed (wineboot exited \(status))."
        }
    }
}

/// Reads runtimes and components installed by the setup wizard. The on-disk layout is shared
/// with the Rust engine: `runtimes/<id>/runtime.json`, `components/dxvk/<version>/{x64,x32}`.
public struct WineRuntimeStore: Sendable {
    public let root: URL

    public init(root: URL = AetherPaths.engineRoot) {
        self.root = root
    }

    public var runtimesDirectory: URL {
        root.appending(path: "runtimes", directoryHint: .isDirectory)
    }

    /// Newest first.
    public func list() -> [WineRuntime] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: runtimesDirectory, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .compactMap { dir -> WineRuntime? in
                guard let data = try? Data(contentsOf: dir.appending(path: "runtime.json")),
                      var runtime = try? JSONDecoder().decode(WineRuntime.self, from: data)
                else { return nil }
                runtime.directory = dir
                return runtime
            }
            .sorted { ($0.installedAt, $1.id) > ($1.installedAt, $0.id) }
    }

    public func newestBase() -> WineRuntime? {
        list().first { $0.flavor == .base }
    }

    /// Flavors available for `baseID` (always includes `.base` when the base exists).
    public func installedFlavors(baseID: String) -> Set<RuntimeFlavor> {
        Set(list().filter { $0.id == baseID || $0.baseId == baseID }.map(\.flavor))
    }

    /// The runtime to launch a `backend` game with.
    public func resolve(baseID: String, backend: TranslationBackend) throws -> WineRuntime {
        let runtimes = list()
        let flavor = RuntimeFlavor.forBackend(backend)
        if flavor == .base {
            guard let base = runtimes.first(where: { $0.id == baseID && $0.flavor == .base }) else { throw WineRuntimeError.noRuntime }
            return base
        }
        guard let derived = runtimes.first(where: { $0.baseId == baseID && $0.flavor == flavor }) else {
            throw WineRuntimeError.backendNotInstalled(backend)
        }
        return derived
    }

    /// Newest installed DXVK component (`components/dxvk/<version>`).
    public func installedDXVK() -> URL? {
        let dir = root.appending(path: "components/dxvk", directoryHint: .isDirectory)
        let versions = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return versions
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }
}

/// Wine prefix ("bottle") preparation.
public enum WinePrefix {
    public static let dxvkDLLs = ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"]

    public static func isInitialized(_ prefix: URL) -> Bool {
        FileManager.default.fileExists(atPath: prefix.appending(path: "drive_c/windows/system32").path(percentEncoded: false))
    }

    /// `wineboot --init` with Mono/Gecko prompts suppressed, then waits for the prefix to settle.
    /// One-time and ~20–60 s on first run.
    public static func initialize(_ prefix: URL, runtime: WineRuntime) async throws {
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        env["WINEPREFIX"] = prefix.path(percentEncoded: false)
        env["WINEDEBUG"] = "-all"
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="

        let status = await run(runtime.wineBinary, ["wineboot", "--init"], environment: env)
        guard status == 0 else { throw WineRuntimeError.prefixInitFailed(status) }
        _ = await run(runtime.wineserver, ["-w"], environment: env)
    }

    /// Copies DXVK into the bottle: 64-bit → `system32`, 32-bit → `syswow64`. Unchanged files are skipped.
    public static func syncDXVK(from dxvk: URL, into prefix: URL) throws {
        let fm = FileManager.default
        let windows = prefix.appending(path: "drive_c/windows", directoryHint: .isDirectory)
        for (arch, target) in [("x64", "system32"), ("x32", "syswow64")] {
            let source = dxvk.appending(path: arch, directoryHint: .isDirectory)
            let destination = windows.appending(path: target, directoryHint: .isDirectory)
            guard fm.fileExists(atPath: source.path(percentEncoded: false)),
                  fm.fileExists(atPath: destination.path(percentEncoded: false)) else { continue }
            for dll in dxvkDLLs {
                let src = source.appending(path: dll)
                let dst = destination.appending(path: dll)
                guard let srcSize = try? fm.attributesOfItem(atPath: src.path(percentEncoded: false))[.size] as? Int else { continue }
                let dstSize = try? fm.attributesOfItem(atPath: dst.path(percentEncoded: false))[.size] as? Int
                if srcSize == dstSize { continue }
                if fm.fileExists(atPath: dst.path(percentEncoded: false)) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
        }
    }

    /// Runs a tool to completion without blocking a thread. Returns its exit status (-1 if it could not start).
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]) async -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            process.terminationHandler = { @Sendable finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }
}
