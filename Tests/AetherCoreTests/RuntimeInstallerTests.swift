import Foundation
import Testing
@testable import AetherCore

@Suite("RuntimeInstaller")
struct RuntimeInstallerTests {

    @Test("Asset selection picks the staging tarball, not devel or checksum files")
    func selectsAsset() throws {
        let json = Data("""
        {"tag_name":"v11.21","assets":[
          {"name":"wine-devel-11.21-osx64.tar.xz","browser_download_url":"https://x/devel","size":1},
          {"name":"wine-staging-11.21-osx64.tar.xz","browser_download_url":"https://x/staging","size":2},
          {"name":"wine-staging-11.21-osx64.tar.xz.sha256","browser_download_url":"https://x/sha","size":3}
        ]}
        """.utf8)
        let asset = try RuntimeInstaller.selectAsset(.wineStaging, from: json)
        #expect(asset.url.absoluteString == "https://x/staging")
        #expect(asset.version == "11.21")

        let empty = Data(#"{"tag_name":"v1","assets":[{"name":"readme","browser_download_url":"https://x/r","size":1}]}"#.utf8)
        #expect(throws: InstallerError.assetNotFound("Wine Staging")) { try RuntimeInstaller.selectAsset(.wineStaging, from: empty) }
    }

    @Test("Slugs match the Rust engine's runtime ids")
    func slugs() {
        #expect(RuntimeInstaller.slugify("Wine Staging-11.21") == "wine-staging-11-21")
        #expect(RuntimeInstaller.slugify("  --Hades II--  ") == "hades-ii")
        #expect(RuntimeInstaller.slugify("名前") == "untitled")
    }

    @Test("Finds the Wine root inside a Gcenx app bundle; relative path is stored")
    func findsWineRoot() throws {
        let fake = try FakeEngineRoot()
        defer { fake.cleanUp() }
        try fake.runtime(id: "w", flavor: "base", baseId: nil, installedAt: 1)
        let dir = fake.root.appending(path: "runtimes/w", directoryHint: .isDirectory)
        let root = try #require(RuntimeInstaller.findDirectory(in: dir, maxDepth: 6) {
            RuntimeInstaller.isFile($0.appending(path: "bin/wineserver"))
        })
        #expect(RuntimeInstaller.relativePath(of: root, to: dir) == "Wine Staging.app/Contents/Resources/wine")
    }

    @Test("Derived runtime: APFS clone + overlay, manifest readable by WineRuntimeStore; failures clean up")
    func deriveRoundTrip() async throws {
        let fake = try FakeEngineRoot()
        defer { fake.cleanUp() }
        try fake.runtime(id: "wine-staging-11-21", flavor: "base", baseId: nil, installedAt: 1)
        let store = WineRuntimeStore(root: fake.root)
        let base = try #require(store.newestBase())
        let installer = RuntimeInstaller(root: fake.root)

        let derived = try await installer.derive(base, flavor: .dxmt, label: "DXMT") { lib in
            try FileManager.default.createDirectory(at: lib.appending(path: "wine/x86_64-unix"), withIntermediateDirectories: true)
            try Data("so".utf8).write(to: lib.appending(path: "wine/x86_64-unix/winemetal.so"))
        }
        #expect(derived.id == "wine-staging-11-21+dxmt")
        #expect(try store.resolve(baseID: base.id, backend: .dxmt).id == derived.id)
        #expect(FileManager.default.fileExists(atPath: derived.libDirectory.appending(path: "wine/x86_64-unix/winemetal.so").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: base.libDirectory.appending(path: "wine/x86_64-unix/winemetal.so").path(percentEncoded: false)))

        await #expect(throws: InstallerError.self) {
            _ = try await installer.derive(base, flavor: .d3dmetal, label: "D3DMetal") { _ in throw InstallerError.invalid("boom") }
        }
        #expect(store.installedFlavors(baseID: base.id) == [.base, .dxmt])
    }

    @Test("GPTK lib is found inside a nested toolkit folder")
    func findsGPTK() throws {
        let fake = try FakeEngineRoot()
        defer { fake.cleanUp() }
        let lib = fake.root.appending(path: "Game Porting Toolkit 3/redist/lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib.appending(path: "external/D3DMetal.framework"), withIntermediateDirectories: true)
        #expect(RuntimeInstaller.findGPTKLib(in: fake.root.appending(path: "Game Porting Toolkit 3"))?.lastPathComponent == "lib")
        #expect(RuntimeInstaller.findGPTKLib(in: fake.root.appending(path: "runtimes")) == nil)
    }

    @Test("Progress fraction")
    func progressFraction() {
        #expect(InstallProgress.downloading(received: 50, total: 200).fraction == 0.25)
        #expect(InstallProgress.downloading(received: 50, total: nil).fraction == nil)
        #expect(InstallProgress.done.fraction == 1)
    }
}
