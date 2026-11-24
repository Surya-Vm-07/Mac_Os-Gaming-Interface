import Foundation
import Testing
@testable import AetherCore

@Suite("GameManifestLoader")
struct GameManifestLoaderTests {

    @Test("Bundled blueprint manifest decodes")
    func bundledManifestDecodes() throws {
        let catalog = try GameManifestLoader(userProfileDirectories: []).load()
        #expect(catalog.issues.isEmpty)

        let cyberpunk = try #require(catalog.profile(steamAppID: "1091500"))
        #expect(cyberpunk.id == "cyberpunk-2077")
        #expect(cyberpunk.preferredEngine == .native)
        #expect(cyberpunk.localTranslation?.backend == .d3dmetal)
        #expect(cyberpunk.localTranslation?.envVars["D3DM_ENABLE_METALFX"] == "1")
        #expect(cyberpunk.localTranslation?.launchArgs == ["--launcher-skip", "-skipStartScreen"])

        let valorant = try #require(catalog.profile(id: "valorant"))
        #expect(valorant.hasKernelAnticheat)
        #expect(valorant.steamAppID == nil)
        #expect(valorant.localTranslation == nil)
        #expect(valorant.preferredEngine == .cloudStream)
        #expect(valorant.cloudFallback?.isAvailable == true)
    }

    @Test("Blueprint's original uppercase engine names still decode")
    func legacyEngineSpelling() throws {
        let json = #"{"schema_version":"1.2","profiles":[{"id":"x","title":"X","has_kernel_anticheat":false,"native_macos_available":false,"min_local_tier":1,"preferred_engine":"METAL_LOCAL"}]}"#
        let manifest = try GameManifestLoader.decode(Data(json.utf8))
        #expect(manifest.profiles.first?.preferredEngine == .localTranslation)
    }

    @Test("Unsupported schema major version is rejected")
    func rejectsFutureSchema() {
        let json = #"{"schema_version":"2.0","profiles":[]}"#
        #expect(throws: ManifestError.unsupportedSchemaVersion("2.0")) {
            try GameManifestLoader.decode(Data(json.utf8))
        }
    }

    @Test("Missing required key gives a path-qualified error")
    func missingKey() {
        let json = #"{"schema_version":"1.0","profiles":[{"id":"x","title":"X"}]}"#
        #expect(throws: ManifestError.self) { try GameManifestLoader.decode(Data(json.utf8)) }
    }

    @Test("User profiles override bundled ones by id; broken files become issues")
    func userOverride() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aether-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let override = #"""
        {"schema_version":"1.0","profiles":[{"id":"cyberpunk-2077","title":"Cyberpunk 2077 (patched)",
          "has_kernel_anticheat":false,"native_macos_available":true,"min_local_tier":3,"preferred_engine":"native"}]}
        """#
        try Data(override.utf8).write(to: dir.appending(path: "10-override.json"))
        try Data("{ not json".utf8).write(to: dir.appending(path: "20-broken.json"))

        let catalog = try GameManifestLoader(userProfileDirectories: [dir]).load()
        #expect(catalog.profile(id: "cyberpunk-2077")?.minLocalTier == 3)
        #expect(catalog.profile(id: "valorant") != nil)
        #expect(catalog.issues.count == 1)
        #expect(catalog.issues.first?.file.lastPathComponent == "20-broken.json")
    }
}
