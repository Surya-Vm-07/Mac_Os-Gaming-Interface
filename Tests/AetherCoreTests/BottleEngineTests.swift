import Foundation
import Testing
@testable import AetherCore

/// The live tests spawn the real `launch_d3dmetal.sh`, with tiny shell scripts standing in for
/// `wine64` / `wineserver`. They need Rosetta 2 (the script runs Wine via `arch -x86_64`).
let rosettaInstalled = FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")

@Suite("BottleEngine")
struct BottleEngineTests {

    // MARK: Pure command construction

    @Test("Launch command: argument order matches launch_d3dmetal.sh")
    func argumentOrder() {
        let runtime = BottleRuntime(
            wineBinary: URL(filePath: "/opt/gptk/bin/wine64"),
            d3dMetalLibraryDirectory: URL(filePath: "/opt/gptk/lib/external"),
            launcherScript: URL(filePath: "/tmp/launch_d3dmetal.sh")
        )
        let request = BottleLaunchRequest(
            executable: URL(filePath: "/Games/My Game/game.exe"),
            bottle: URL(filePath: "/Bottles/my-game"),
            translation: Fixtures.d3dmetal,
            metalHUDEnabled: false,
            additionalArguments: ["-windowed"]
        )
        let command = BottleEngine.makeLaunchCommand(for: request, runtime: runtime, baseEnvironment: [:])

        #expect(command.executableURL.path(percentEncoded: false) == "/bin/zsh")
        #expect(command.arguments == [
            "/tmp/launch_d3dmetal.sh",
            "/Bottles/my-game",
            "/opt/gptk/bin/wine64",
            "/opt/gptk/lib/external",
            "/Games/My Game/game.exe", // spaces survive: no shell string building
            "0",
            "-dx12",
            "-windowed",
        ])
        #expect(command.workingDirectory.path(percentEncoded: false).hasSuffix("/Games/My Game/"))
        #expect(runtime.wineserverBinary.path(percentEncoded: false) == "/opt/gptk/bin/wineserver")
    }

    @Test("Environment precedence: base < profile < request < engine; DYLD_* dropped")
    func environmentPrecedence() {
        let runtime = BottleRuntime(
            wineBinary: URL(filePath: "/w/wine64"),
            d3dMetalLibraryDirectory: URL(filePath: "/w/lib"),
            launcherScript: URL(filePath: "/w/launch.sh")
        )
        var translation = Fixtures.d3dmetal
        translation.envVars["MTL_HUD_ENABLED"] = "0"          // the user toggle must win over this
        translation.envVars["DYLD_INSERT_LIBRARIES"] = "/evil" // must never pass through
        let request = BottleLaunchRequest(
            executable: URL(filePath: "/g/game.exe"),
            bottle: URL(filePath: "/b/game"),
            translation: translation,
            metalHUDEnabled: true,
            additionalEnvironment: ["WINEMSYNC": "0"]
        )
        let env = BottleEngine.makeLaunchCommand(
            for: request,
            runtime: runtime,
            baseEnvironment: ["PATH": "/usr/bin", "D3DM_ENABLE_METALFX": "0", "DYLD_LIBRARY_PATH": "/x"]
        ).environment

        #expect(env["PATH"] == "/usr/bin")
        #expect(env["D3DM_ENABLE_METALFX"] == "1")   // profile beats inherited
        #expect(env["WINEMSYNC"] == "0")             // request beats profile
        #expect(env["MTL_HUD_ENABLED"] == "1")       // engine-owned
        #expect(env["WINEPREFIX"] == "/b/game")
        #expect(env.keys.contains { $0.hasPrefix("DYLD_") } == false)
    }

    // MARK: Validation (no spawn)

    @Test("Missing executable fails fast, before spawning")
    func missingExecutable() async throws {
        let sandbox = try FakeToolchain()
        defer { sandbox.cleanUp() }
        let engine = BottleEngine(runtime: sandbox.runtime)
        var request = sandbox.request
        request.executable = sandbox.root.appending(path: "nope.exe")

        await #expect(throws: BottleEngineError.executableNotFound(request.executable.path(percentEncoded: false))) {
            _ = try await engine.launch(request)
        }
        #expect(await engine.state == .idle)
    }

    @Test("DXVK backend is rejected in Phase 1")
    func dxvkRejected() async throws {
        let sandbox = try FakeToolchain()
        defer { sandbox.cleanUp() }
        let engine = BottleEngine(runtime: sandbox.runtime)
        var request = sandbox.request
        request.translation.backend = .dxvk

        await #expect(throws: BottleEngineError.unsupportedBackend(.dxvk)) {
            _ = try await engine.launch(request)
        }
    }

    // MARK: Live process tests

    @Test("Streams stdout/stderr lines, flushes partial lines, reports exit code",
          .enabled(if: rosettaInstalled), .timeLimit(.minutes(1)))
    func streamsLogsAndExit() async throws {
        let sandbox = try FakeToolchain(wineScript: """
        #!/bin/sh
        echo "fake-wine: $1"
        echo "warning line" >&2
        printf 'partial-no-newline'
        exit 3
        """)
        defer { sandbox.cleanUp() }

        let engine = BottleEngine(runtime: sandbox.runtime)
        let events = try await engine.launch(sandbox.request)

        var collected: [BottleEvent] = []
        for await event in events { collected.append(event) }

        guard case .launched = collected.first else {
            Issue.record("First event must be .launched, got \(String(describing: collected.first))")
            return
        }
        #expect(collected.contains(.stdout("fake-wine: \(sandbox.request.executable.path(percentEncoded: false))")))
        #expect(collected.contains(.stderr("warning line")))
        #expect(collected.contains(.stdout("partial-no-newline")))
        #expect(collected.last == .processExited(BottleExit(reason: .exited, status: 3)))
        #expect(await engine.state == .idle)
    }

    @Test("terminate() stops a hung game with SIGTERM and returns the engine to idle",
          .enabled(if: rosettaInstalled), .timeLimit(.minutes(1)))
    func terminatesHungGame() async throws {
        let sandbox = try FakeToolchain(wineScript: """
        #!/bin/sh
        echo "game running"
        exec /bin/sleep 600
        """)
        defer { sandbox.cleanUp() }

        let engine = BottleEngine(runtime: sandbox.runtime)
        let events = try await engine.launch(sandbox.request)
        let collector = Task {
            var all: [BottleEvent] = []
            for await event in events { all.append(event) }
            return all
        }

        try await Task.sleep(for: .milliseconds(500))
        await #expect(throws: BottleEngineError.self) { _ = try await engine.launch(sandbox.request) } // one session at a time

        await engine.terminate(gracePeriod: .seconds(2))
        let all = await collector.value

        #expect(all.last == .processExited(BottleExit(reason: .signaled, status: SIGTERM)))
        #expect(await engine.state == .idle)
    }
}

// MARK: - Fake toolchain

/// A temporary directory with fake `wine64` / `wineserver` scripts, a D3DMetal dir, a dummy .exe,
/// and the real bundled `launch_d3dmetal.sh`.
struct FakeToolchain {
    let root: URL
    let runtime: BottleRuntime
    let request: BottleLaunchRequest

    init(wineScript: String = "#!/bin/sh\nexit 0\n") throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "aether-bottle-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        let lib = root.appending(path: "lib/external", directoryHint: .isDirectory)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)

        let wine = bin.appending(path: "wine64")
        let wineserver = bin.appending(path: "wineserver")
        try Data(wineScript.utf8).write(to: wine)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wineserver)
        for tool in [wine, wineserver] {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        }

        let exe = root.appending(path: "Game Folder/game.exe")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)

        runtime = BottleRuntime(wineBinary: wine, d3dMetalLibraryDirectory: lib)
        request = BottleLaunchRequest(
            executable: exe,
            bottle: root.appending(path: "bottle", directoryHint: .isDirectory),
            translation: Fixtures.d3dmetal,
            metalHUDEnabled: false
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
