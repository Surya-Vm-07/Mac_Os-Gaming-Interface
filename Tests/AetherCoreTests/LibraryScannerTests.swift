import Foundation
import Testing
@testable import AetherCore

/// Builds a throwaway file tree that looks like Steam libraries, /Applications and a games folder.
struct FakeLibrary {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "aether-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ path: String) -> URL { root.appending(path: path) }

    @discardableResult
    func file(_ path: String, _ contents: String = "", bytes: Int = 0) throws -> URL {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = contents.isEmpty ? Data(count: bytes) : Data(contents.utf8)
        try data.write(to: url)
        return url
    }

    func appBundle(_ path: String, name: String, bundleID: String, category: String?) throws {
        var plist: [String: Any] = ["CFBundleName": name, "CFBundleIdentifier": bundleID]
        if let category { plist["LSApplicationCategoryType"] = category }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let url = url("\(path)/Contents/Info.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func manifest(appID: String, name: String, installdir: String, flags: Int = 4) -> String {
        """
        "AppState"
        {
        \t"appid"\t\t"\(appID)"
        \t"name"\t\t"\(name)"
        \t"installdir"\t\t"\(installdir)"
        \t"StateFlags"\t\t"\(flags)"
        }
        """
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite("LibraryScanner")
struct LibraryScannerTests {

    @Test("Steam: follows libraryfolders.vdf, skips partial installs and redistributables, finds .app and .exe")
    func steamLibraries() throws {
        let lib = try FakeLibrary()
        defer { lib.cleanUp() }

        let steam = lib.url("Steam")
        let external = lib.url("SSD/SteamLibrary")
        try lib.file("Steam/steamapps/libraryfolders.vdf", """
        "libraryfolders"
        {
            "0" { "path" "\(steam.path(percentEncoded: false))" }
            "1" { "path" "\(external.path(percentEncoded: false))" }
        }
        """)
        // Native game in the default library.
        try lib.file("Steam/steamapps/appmanifest_400.acf", FakeLibrary.manifest(appID: "400", name: "Portal", installdir: "Portal"))
        try lib.appBundle("Steam/steamapps/common/Portal/Portal.app", name: "Portal", bundleID: "com.valve.portal", category: "public.app-category.games")
        // Windows game on the external SSD, with decoy executables.
        try lib.file("SSD/SteamLibrary/steamapps/appmanifest_1091500.acf",
                     FakeLibrary.manifest(appID: "1091500", name: "Cyberpunk 2077", installdir: "Cyberpunk 2077"))
        try lib.file("SSD/SteamLibrary/steamapps/common/Cyberpunk 2077/bin/x64/Cyberpunk2077.exe", bytes: 1000)
        try lib.file("SSD/SteamLibrary/steamapps/common/Cyberpunk 2077/unins000.exe", bytes: 9000)
        // Partially downloaded (no StateFullyInstalled bit) and a redistributable: both skipped.
        try lib.file("SSD/SteamLibrary/steamapps/appmanifest_999.acf", FakeLibrary.manifest(appID: "999", name: "Downloading", installdir: "X", flags: 1026))
        try lib.file("Steam/steamapps/appmanifest_228980.acf", FakeLibrary.manifest(appID: "228980", name: "Steamworks Common Redistributables", installdir: "Steamworks Shared"))

        let catalog = try GameManifestLoader(userProfileDirectories: []).load()
        let scanner = LibraryScanner(
            configuration: .init(steamRoots: [steam], applicationDirectories: []),
            catalog: catalog
        )
        let result = scanner.scan()

        #expect(result.games.map(\.title) == ["Cyberpunk 2077", "Portal"])
        #expect(result.issues.isEmpty)

        let cyberpunk = try #require(result.games.first { $0.steamAppID == "1091500" })
        #expect(cyberpunk.profileID == "cyberpunk-2077")
        #expect(cyberpunk.installation.windowsExecutable?.lastPathComponent == "Cyberpunk2077.exe")
        #expect(cyberpunk.installation.nativeApplication == nil)

        let portal = try #require(result.games.first { $0.steamAppID == "400" })
        #expect(portal.installation.nativeApplication?.lastPathComponent == "Portal.app")
    }

    @Test("Executable heuristic without a hint: largest non-installer .exe wins")
    func executableHeuristic() throws {
        let lib = try FakeLibrary()
        defer { lib.cleanUp() }
        try lib.file("Game/Game.exe", bytes: 5000)
        try lib.file("Game/Engine/Binaries/Win64/GameShipping.exe", bytes: 50_000)
        try lib.file("Game/_CommonRedist/vc_redist.x64.exe", bytes: 900_000)
        try lib.file("Game/EasyAntiCheat/EasyAntiCheat_Setup.exe", bytes: 900_000)
        try lib.file("Game/Deep/A/B/C/D/TooDeep.exe", bytes: 9_000_000) // depth 6, beyond the cap

        let exe = LibraryScanner.findWindowsExecutable(in: lib.url("Game"), hint: nil)
        #expect(exe?.lastPathComponent == "GameShipping.exe")
    }

    @Test("Wine prefix: C:\\ paths map into drive_c")
    func winePrefixPathMapping() throws {
        let lib = try FakeLibrary()
        defer { lib.cleanUp() }
        let steamRoot = lib.url("Bottles/steam/drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steamRoot, withIntermediateDirectories: true)

        let mapped = LibraryScanner.resolveSteamPath(#"C:\Games\SteamLibrary"#, steamRoot: steamRoot)
        #expect(mapped?.lastPathComponent == "SteamLibrary")
        #expect(mapped?.path(percentEncoded: false).contains("Bottles/steam/drive_c/Games/SteamLibrary") == true)

        let otherDrive = LibraryScanner.resolveSteamPath(#"D:\SteamLibrary"#, steamRoot: steamRoot)
        #expect(otherDrive?.path(percentEncoded: false).contains("dosdevices/d:/SteamLibrary") == true)

        #expect(LibraryScanner.resolveSteamPath(#"C:\x"#, steamRoot: lib.url("NotAPrefix")) == nil)
    }

    @Test("Applications: only games-category apps; custom folders: .app, .exe, and game folders")
    func applicationsAndCustomFolders() throws {
        let lib = try FakeLibrary()
        defer { lib.cleanUp() }
        try lib.appBundle("Apps/Baldur's Gate 3.app", name: "Baldur's Gate 3", bundleID: "com.larian.bg3", category: "public.app-category.role-playing-games")
        try lib.appBundle("Apps/Games/Celeste.app", name: "Celeste", bundleID: "com.mattmakesgames.celeste", category: "public.app-category.games")
        try lib.appBundle("Apps/Notes.app", name: "Notes", bundleID: "com.apple.Notes", category: "public.app-category.productivity")
        try lib.file("Custom/Hades/Hades.exe", bytes: 100)
        try lib.file("Custom/Loose.exe", bytes: 100)
        try lib.file("Custom/EmptyFolder/readme.txt", "hi")

        let scanner = LibraryScanner(configuration: .init(
            steamRoots: [],
            applicationDirectories: [lib.url("Apps")],
            customDirectories: [lib.url("Custom")]
        ))
        let titles = scanner.scan().games.map(\.title)
        #expect(titles == ["Baldur's Gate 3", "Celeste", "Hades", "Loose"])
    }

    @Test("Deduplication: Steam entry wins and absorbs the native .app from /Applications")
    func deduplication() {
        let steam = GameItem(id: "steam:1", title: "DOOM Eternal", source: .steam(appID: "1"),
                             installation: GameInstallation(windowsExecutable: URL(filePath: "/g/doom.exe")))
        let app = GameItem(id: "app:doom", title: "Doom: Eternal", source: .macApplication,
                           installation: GameInstallation(nativeApplication: URL(filePath: "/Applications/Doom.app")))
        let merged = LibraryScanner.deduplicate([app, steam])
        #expect(merged.count == 1)
        #expect(merged.first?.id == "steam:1")
        #expect(merged.first?.installation.nativeApplication?.lastPathComponent == "Doom.app")
        #expect(merged.first?.installation.windowsExecutable?.lastPathComponent == "doom.exe")
    }
}

@Suite("GridNavigator")
struct GridNavigatorTests {
    // 7 items, 3 columns:
    // 0 1 2
    // 3 4 5
    // 6
    @Test func edgesStop() {
        #expect(GridNavigator.move(from: 0, .left, count: 7, columns: 3) == 0)
        #expect(GridNavigator.move(from: 2, .right, count: 7, columns: 3) == 2)
        #expect(GridNavigator.move(from: 1, .up, count: 7, columns: 3) == 1)
        #expect(GridNavigator.move(from: 6, .down, count: 7, columns: 3) == 6)
        #expect(GridNavigator.move(from: 6, .right, count: 7, columns: 3) == 6)
    }

    @Test func movesWithinGrid() {
        #expect(GridNavigator.move(from: 4, .left, count: 7, columns: 3) == 3)
        #expect(GridNavigator.move(from: 4, .right, count: 7, columns: 3) == 5)
        #expect(GridNavigator.move(from: 4, .up, count: 7, columns: 3) == 1)
        #expect(GridNavigator.move(from: 1, .down, count: 7, columns: 3) == 4)
    }

    @Test("Down onto a shorter last row lands on its last item")
    func partialLastRow() {
        #expect(GridNavigator.move(from: 5, .down, count: 7, columns: 3) == 6)
    }

    @Test func degenerateInputs() {
        #expect(GridNavigator.move(from: 0, .down, count: 0, columns: 3) == 0)
        #expect(GridNavigator.move(from: 99, .left, count: 4, columns: 0) == 3) // clamped to last; 1 column, left stays
        #expect(GridNavigator.move(from: 99, .up, count: 4, columns: 0) == 2)
    }
}

@Suite("Add Games detection")
struct AddGamesDetectionTests {
    @Test("A game's own folder is one game; a folder of games is a library folder")
    func singleGameVersusLibrary() throws {
        let lib = try FakeLibrary()
        defer { lib.cleanUp() }
        // A drive/folder holding several games.
        try lib.file("SSD/Games/Hades/Hades.exe", bytes: 10)
        try lib.file("SSD/Games/Celeste/Celeste.exe", bytes: 10)
        // One Unreal-style game picked directly.
        try lib.file("SSD/Games/Cyberpunk 2077/bin/x64/Cyberpunk2077.exe", bytes: 10)
        try lib.file("SSD/Games/Cyberpunk 2077/engine/config.ini", "x")
        try lib.file("SSD/Games/Cyberpunk 2077/archive/pc.archive", "x")

        #expect(!LibraryScanner.looksLikeSingleGame(lib.url("SSD/Games")))
        #expect(LibraryScanner.looksLikeSingleGame(lib.url("SSD/Games/Hades")))
        #expect(LibraryScanner.looksLikeSingleGame(lib.url("SSD/Games/Cyberpunk 2077")))
        #expect(LibraryScanner.findWindowsExecutable(in: lib.url("SSD/Games/Cyberpunk 2077"), hint: nil)?.lastPathComponent == "Cyberpunk2077.exe")

        let scanned = LibraryScanner(configuration: .init(steamRoots: [], applicationDirectories: [], customDirectories: [lib.url("SSD/Games")]))
        #expect(scanned.scan().games.map(\.title) == ["Celeste", "Cyberpunk 2077", "Hades"])
    }
}
