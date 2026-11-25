import Foundation
import Testing
@testable import AetherCore

/// Writes runtimes in the exact `runtime.json` shape the setup wizard (Rust engine) produces.
struct FakeEngineRoot {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "aether-engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func runtime(id: String, flavor: String, baseId: String?, installedAt: Int) throws {
        let dir = root.appending(path: "runtimes/\(id)", directoryHint: .isDirectory)
        let bin = dir.appending(path: "Wine Staging.app/Contents/Resources/wine/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["wine", "wineserver"] {
            let url = bin.appending(path: tool)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        }
        let base = baseId.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id":"\(id)","name":"Wine Staging","version":"11.21","flavor":"\(flavor)","baseId":\(base),
         "wineRoot":"Wine Staging.app/Contents/Resources/wine","installedAt":\(installedAt)}
        """
        try Data(json.utf8).write(to: dir.appending(path: "runtime.json"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite("WineRuntimeStore")
struct WineRuntimeStoreTests {
    @Test("Reads wizard runtimes, resolves flavors per backend, reports what is missing")
    func resolveFlavors() throws {
        let fake = try FakeEngineRoot()
        defer { fake.cleanUp() }
        try fake.runtime(id: "wine-staging-11-21", flavor: "base", baseId: nil, installedAt: 100)
        try fake.runtime(id: "wine-staging-11-21+dxmt", flavor: "dxmt", baseId: "wine-staging-11-21", installedAt: 200)
        try Data("not json".utf8).write(to: fake.root.appending(path: "runtimes/junk.json"))

        let store = WineRuntimeStore(root: fake.root)
        let base = try #require(store.newestBase())
        #expect(base.id == "wine-staging-11-21")
        #expect(base.wineBinary.path(percentEncoded: false).hasSuffix("Resources/wine/bin/wine"))
        #expect(FileManager.default.isExecutableFile(atPath: base.wineserver.path(percentEncoded: false)))
        #expect(store.installedFlavors(baseID: base.id) == [.base, .dxmt])

        #expect(try store.resolve(baseID: base.id, backend: .dxmt).id == "wine-staging-11-21+dxmt")
        #expect(try store.resolve(baseID: base.id, backend: .wined3d).id == base.id)
        #expect(try store.resolve(baseID: base.id, backend: .dxvk).id == base.id)
        #expect(throws: WineRuntimeError.backendNotInstalled(.d3dmetal)) {
            try store.resolve(baseID: base.id, backend: .d3dmetal)
        }
        #expect(store.installedDXVK() == nil)
    }

    @Test("No runtimes → actionable errors")
    func empty() throws {
        let fake = try FakeEngineRoot()
        defer { fake.cleanUp() }
        let store = WineRuntimeStore(root: fake.root)
        #expect(store.newestBase() == nil)
        #expect(throws: WineRuntimeError.noRuntime) { try store.resolve(baseID: "x", backend: .wined3d) }
    }

    @Test("DXVK sync copies 64-bit to system32 and 32-bit to syswow64")
    func dxvkSync() throws {
        let fake = try FakeEngineRoot()
        defer { fake.cleanUp() }
        let fm = FileManager.default
        let dxvk = fake.root.appending(path: "components/dxvk/1.10.3", directoryHint: .isDirectory)
        for arch in ["x64", "x32"] {
            try fm.createDirectory(at: dxvk.appending(path: arch), withIntermediateDirectories: true)
            for dll in WinePrefix.dxvkDLLs { try Data("\(arch)-\(dll)".utf8).write(to: dxvk.appending(path: "\(arch)/\(dll)")) }
        }
        let prefix = fake.root.appending(path: "bottle", directoryHint: .isDirectory)
        for dir in ["system32", "syswow64"] {
            try fm.createDirectory(at: prefix.appending(path: "drive_c/windows/\(dir)"), withIntermediateDirectories: true)
        }
        #expect(WinePrefix.isInitialized(prefix))
        #expect(WineRuntimeStore(root: fake.root).installedDXVK()?.lastPathComponent == "1.10.3")

        try WinePrefix.syncDXVK(from: dxvk, into: prefix)
        try WinePrefix.syncDXVK(from: dxvk, into: prefix) // idempotent
        #expect(try String(contentsOf: prefix.appending(path: "drive_c/windows/system32/d3d11.dll"), encoding: .utf8) == "x64-d3d11.dll")
        #expect(try String(contentsOf: prefix.appending(path: "drive_c/windows/syswow64/dxgi.dll"), encoding: .utf8) == "x32-dxgi.dll")
    }
}

@Suite("WineEnvironment & presets")
struct WineEnvironmentTests {
    let prefix = URL(filePath: "/b/game", directoryHint: .isDirectory)

    @Test("Preset forces its backend and variables")
    func presetVars() {
        let env = WineEnvironment.build(prefix: prefix, preset: .dx12AAA, backend: .dxvk, metalHUD: false)
        #expect(env["WINEDLLOVERRIDES"] == TranslationBackend.d3dmetal.dllOverrides)
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["ROSETTA_ADVERTISE_AVX"] == "1")
        #expect(env["D3DM_ENABLE_METALFX"] == "1")
        #expect(env["MTL_HUD_ENABLED"] == "0")
        #expect(env["WINEPREFIX"] == "/b/game/")
    }

    @Test("Precedence: preset < profile < HUD toggle < user; prefix pinned; DYLD blocked")
    func precedence() {
        let env = WineEnvironment.build(
            prefix: prefix,
            preset: .maxFPS,
            backend: .d3dmetal,
            metalHUD: true,
            dxmtConfig: "  d3d11.preferredMaxFrameRate=60 ",
            profileEnvironment: ["MTL_HUD_ENABLED": "0", "WINEESYNC": "0", "DYLD_INSERT_LIBRARIES": "/evil"],
            userOverrides: ["WINEMSYNC": "0", "WINEPREFIX": "/elsewhere", " ": "x"]
        )
        #expect(env["MTL_HUD_ENABLED"] == "1", "user toggle beats the profile")
        #expect(env["WINEESYNC"] == "0", "profile beats preset")
        #expect(env["WINEMSYNC"] == "0", "user beats preset")
        #expect(env["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=60")
        #expect(env["WINEPREFIX"] == "/b/game/")
        #expect(!env.keys.contains { $0.hasPrefix("DYLD_") || $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    @Test("Custom keeps the game's backend and adds no preset vars")
    func custom() {
        let env = WineEnvironment.build(prefix: prefix, preset: .custom, backend: .dxvk, metalHUD: false)
        #expect(env["WINEDLLOVERRIDES"] == "d3d9,d3d10core,d3d11,dxgi=n,b")
        #expect(env["WINEMSYNC"] == nil)
    }

    @Test("Recommended preset follows what is installed")
    func recommendation() {
        #expect(PerformancePreset.recommended(profileBackend: .d3dmetal, installed: [.base, .d3dmetal, .dxmt]) == .dx12AAA)
        #expect(PerformancePreset.recommended(profileBackend: .d3dmetal, installed: [.base, .dxmt]) == .dx11DXMT)
        #expect(PerformancePreset.recommended(profileBackend: .dxvk, installed: [.base, .d3dmetal, .dxmt]) == .dx11DXMT)
        #expect(PerformancePreset.recommended(profileBackend: .d3dmetal, installed: [.base]) == .compatibility)
    }

    @Test("Direct launch command: wine <exe> <args> with built env")
    func directCommand() {
        let wine = WineRuntime(id: "w", name: "Wine", version: "11", flavor: .dxmt, baseId: "b",
                               wineRoot: "wine", installedAt: 0, directory: URL(filePath: "/rt/w", directoryHint: .isDirectory))
        let request = BottleLaunchRequest(
            executable: URL(filePath: "/Games/Hades/Hades.exe"),
            bottle: URL(filePath: "/b/hades", directoryHint: .isDirectory),
            translation: LocalTranslationConfig(backend: .dxmt, launchArgs: ["-windowed"]),
            metalHUDEnabled: false,
            preset: .dx11DXMT
        )
        let command = BottleEngine.makeLaunchCommand(for: request, runtime: BottleRuntime(runtime: wine), baseEnvironment: ["DYLD_X": "1", "HOME": "/h"])
        #expect(command.executableURL.path(percentEncoded: false) == "/rt/w/wine/bin/wine")
        #expect(command.arguments == ["/Games/Hades/Hades.exe", "-windowed"])
        #expect(command.environment["WINEDLLOVERRIDES"] == TranslationBackend.dxmt.dllOverrides)
        #expect(command.environment["HOME"] == "/h")
        #expect(command.environment["DYLD_X"] == nil)
        #expect(command.workingDirectory.path(percentEncoded: false).hasSuffix("/Games/Hades/"))
    }
}
