import Foundation

public struct LibraryScanResult: Sendable {
    public let games: [GameItem]
    /// Non-fatal problems (unparseable manifests and similar), for a diagnostics screen.
    public let issues: [String]
}

/// Builds the library from three sources:
/// 1. Steam libraries: `libraryfolders.vdf` → every library path → `appmanifest_*.acf`.
///    Works for macOS Steam and for Windows Steam installed inside a Wine prefix
///    (it maps `C:\...` paths to `<prefix>/drive_c/...`).
/// 2. Games-category apps in `/Applications` and `~/Applications`.
/// 3. User folders: each `.app`, `.exe` or game folder directly inside them.
///
/// Blocking file I/O. Call it off the main actor (`Task.detached`).
public struct LibraryScanner: Sendable {

    public struct Configuration: Sendable, Equatable {
        public var steamRoots: [URL]
        public var applicationDirectories: [URL]
        public var customDirectories: [URL]
        /// Games added by hand (installed into a bottle). Loaded fresh for every scan.
        public var manualGames: [ManualGame]

        public init(steamRoots: [URL], applicationDirectories: [URL], customDirectories: [URL] = [], manualGames: [ManualGame] = []) {
            self.steamRoots = steamRoots
            self.applicationDirectories = applicationDirectories
            self.customDirectories = customDirectories
            self.manualGames = manualGames
        }

        /// macOS Steam plus both Applications folders.
        public static var standard: Configuration {
            Configuration(
                steamRoots: [URL.applicationSupportDirectory.appending(path: "Steam", directoryHint: .isDirectory)],
                applicationDirectories: [
                    URL(filePath: "/Applications", directoryHint: .isDirectory),
                    URL.homeDirectory.appending(path: "Applications", directoryHint: .isDirectory),
                ],
                // Drop Windows game folders or .exe files here; each one becomes a library entry.
                customDirectories: [URL.documentsDirectory.appending(path: "Aether Games", directoryHint: .isDirectory)],
                manualGames: ManualGameStore.load()
            )
        }
    }

    /// Steam tool depots that look like games in the manifests.
    static let ignoredSteamAppIDs: Set<String> = [
        "228980", // Steamworks Common Redistributables
    ]

    /// `.exe` names that are never the game itself.
    static let excludedExecutableFragments = [
        "unins", "setup", "install", "redist", "vcredist", "vc_redist", "dxsetup", "directx", "dotnet",
        "crash", "report", "helper", "prereq", "easyanticheat", "eac_", "be_service", "battleye",
        "cefprocess", "webhelper", "updater",
    ]

    /// Unreal games keep the real binary at `<Game>/Binaries/Win64/<Game>-Win64-Shipping.exe` (depth 4).
    static let maxExecutableDepth = 5

    /// Safety cap so a huge install folder cannot stall a scan.
    static let maxEnumeratedFiles = 20_000

    public var configuration: Configuration
    public var catalog: ProfileCatalog?

    public init(configuration: Configuration = .standard, catalog: ProfileCatalog? = nil) {
        self.configuration = configuration
        self.catalog = catalog
    }

    public func scan() -> LibraryScanResult {
        var issues: [String] = []
        var games = scanSteam(issues: &issues)
        games += scanApplications()
        games += scanCustomFolders()
        games += configuration.manualGames
            .filter { FileManager.default.fileExists(atPath: $0.executable.path(percentEncoded: false)) }
            .map { manual in
                GameItem(
                    id: "manual:\(manual.id)",
                    title: manual.title,
                    source: .customFolder,
                    installation: GameInstallation(windowsExecutable: manual.executable),
                    installDirectory: manual.executable.deletingLastPathComponent(),
                    profileID: profileID(matchingTitle: manual.title),
                    bottleOverride: manual.bottle
                )
            }
        let merged = Self.deduplicate(games).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return LibraryScanResult(games: merged, issues: issues)
    }

    // MARK: - Steam

    func scanSteam(issues: inout [String]) -> [GameItem] {
        let fm = FileManager.default
        var seenLibraries = Set<String>()
        var seenApps = Set<String>()
        var games: [GameItem] = []

        for root in configuration.steamRoots {
            for library in Self.steamLibraries(root: root, issues: &issues) {
                guard seenLibraries.insert(library.standardizedFileURL.path(percentEncoded: false)).inserted else { continue }
                let steamapps = library.appending(path: "steamapps", directoryHint: .isDirectory)
                guard let entries = try? fm.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil) else { continue }

                let manifests = entries
                    .filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }

                for manifest in manifests {
                    do {
                        guard let game = try parseAppManifest(manifest, steamapps: steamapps),
                              let appID = game.steamAppID,
                              seenApps.insert(appID).inserted
                        else { continue }
                        games.append(game)
                    } catch {
                        issues.append("\(manifest.lastPathComponent): \(error)")
                    }
                }
            }
        }
        return games
    }

    /// The root itself plus every library listed in `libraryfolders.vdf`, in the modern format
    /// (`"0" { "path" "..." }`) or the pre-2021 format (`"1" "D:\\SteamLibrary"`).
    static func steamLibraries(root: URL, issues: inout [String]) -> [URL] {
        var libraries = [root]
        for candidate in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
            let url = root.appending(path: candidate)
            guard let text = readText(url) else { continue }
            do {
                guard let folders = try VDFParser.parse(text)["libraryfolders"] else { continue }
                for entry in folders.children where Int(entry.key) != nil {
                    if let raw = entry["path"]?.stringValue ?? entry.stringValue,
                       let library = resolveSteamPath(raw, steamRoot: root) {
                        libraries.append(library)
                    }
                }
            } catch {
                issues.append("\(url.lastPathComponent): \(error)")
            }
        }
        return libraries
    }

    /// Maps a path from a Steam config to a macOS URL. Windows drive paths (`C:\Games`) only
    /// make sense inside a Wine prefix: drive C maps to `<prefix>/drive_c`, other drives to
    /// `<prefix>/dosdevices/<x>:`.
    static func resolveSteamPath(_ raw: String, steamRoot: URL) -> URL? {
        let chars = Array(raw)
        let isWindowsDrivePath = chars.count >= 2 && chars[0].isLetter && chars[1] == ":"
        guard isWindowsDrivePath else {
            return URL(filePath: raw, directoryHint: .isDirectory)
        }
        guard let prefix = winePrefix(containing: steamRoot) else { return nil }
        let drive = String(chars[0]).lowercased()
        let relative = String(chars.dropFirst(2))
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = drive == "c"
            ? prefix.appending(path: "drive_c", directoryHint: .isDirectory)
            : prefix.appending(path: "dosdevices/\(drive):", directoryHint: .isDirectory)
        return relative.isEmpty ? base : base.appending(path: relative, directoryHint: .isDirectory)
    }

    /// Walks up from `url` to the first directory that contains `drive_c`.
    static func winePrefix(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: current.appending(path: "drive_c").path(percentEncoded: false)) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { return nil }
            current = parent
        }
        return nil
    }

    func parseAppManifest(_ url: URL, steamapps: URL) throws -> GameItem? {
        guard let text = Self.readText(url) else { throw ScanError.unreadable }
        guard let state = try VDFParser.parse(text)["AppState"],
              let appID = state["appid"]?.stringValue,
              let name = state["name"]?.stringValue,
              let installdir = state["installdir"]?.stringValue
        else { throw ScanError.malformedManifest }

        guard !Self.ignoredSteamAppIDs.contains(appID) else { return nil }
        // StateFlags bit 4 = StateFullyInstalled. Skip downloads and uninstalled games.
        let flags = Int(state["StateFlags"]?.stringValue ?? "") ?? 0
        guard flags & 4 != 0 else { return nil }

        let installDirectory = steamapps
            .appending(path: "common", directoryHint: .isDirectory)
            .appending(path: installdir, directoryHint: .isDirectory)
        let profile = catalog?.profile(steamAppID: appID)

        return GameItem(
            id: "steam:\(appID)",
            title: name,
            source: .steam(appID: appID),
            installation: Self.detectInstallation(in: installDirectory, executableHint: profile?.localTranslation?.executable),
            installDirectory: installDirectory,
            profileID: profile?.id
        )
    }

    enum ScanError: Error, CustomStringConvertible {
        case unreadable
        case malformedManifest

        var description: String {
            switch self {
            case .unreadable: "file could not be read"
            case .malformedManifest: "missing AppState/appid/name/installdir"
            }
        }
    }

    // MARK: - Applications

    func scanApplications() -> [GameItem] {
        var games: [GameItem] = []
        for directory in configuration.applicationDirectories {
            // Top level plus one folder deep (e.g. /Applications/Games/Foo.app).
            for app in Self.applicationBundles(in: directory, depth: 1) {
                guard let info = Self.infoPlist(of: app), Self.isGame(info) else { continue }
                games.append(makeAppItem(app, info: info, source: .macApplication))
            }
        }
        return games
    }

    func makeAppItem(_ app: URL, info: [String: Any], source: GameItem.Source) -> GameItem {
        let title = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        let bundleID = info["CFBundleIdentifier"] as? String
        return GameItem(
            id: "app:\(bundleID ?? app.path(percentEncoded: false))",
            title: title,
            source: source,
            installation: GameInstallation(nativeApplication: app),
            installDirectory: app,
            profileID: profileID(matchingTitle: title)
        )
    }

    static func applicationBundles(in directory: URL, depth: Int) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var bundles: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if entry.pathExtension == "app" {
                bundles.append(entry)
            } else if depth > 0, (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                bundles += applicationBundles(in: entry, depth: depth - 1)
            }
        }
        return bundles
    }

    /// Reads `Contents/Info.plist` directly. `Bundle(url:)` would keep every scanned bundle in
    /// Foundation's process-wide bundle cache for the life of the app.
    static func infoPlist(of app: URL) -> [String: Any]? {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// `public.app-category.games` and its subcategories (`...action-games`, `...puzzle-games`, ...).
    static func isGame(_ info: [String: Any]) -> Bool {
        (info["LSApplicationCategoryType"] as? String)?.hasSuffix("games") == true
    }

    // MARK: - Custom folders

    func scanCustomFolders() -> [GameItem] {
        let fm = FileManager.default
        var games: [GameItem] = []
        for directory in configuration.customDirectories {
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let path = entry.path(percentEncoded: false)
                if entry.pathExtension == "app" {
                    games.append(makeAppItem(entry, info: Self.infoPlist(of: entry) ?? [:], source: .customFolder))
                } else if entry.pathExtension.lowercased() == "exe" {
                    let title = entry.deletingPathExtension().lastPathComponent
                    games.append(GameItem(
                        id: "custom:\(path)",
                        title: title,
                        source: .customFolder,
                        installation: GameInstallation(windowsExecutable: entry),
                        installDirectory: entry.deletingLastPathComponent(),
                        profileID: profileID(matchingTitle: title)
                    ))
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let title = entry.lastPathComponent
                    let matchedProfileID = profileID(matchingTitle: title)
                    let hint = matchedProfileID.flatMap { catalog?.profile(id: $0)?.localTranslation?.executable }
                    let installation = Self.detectInstallation(in: entry, executableHint: hint)
                    guard installation.nativeApplication != nil || installation.windowsExecutable != nil else { continue }
                    games.append(GameItem(
                        id: "custom:\(path)",
                        title: title,
                        source: .customFolder,
                        installation: installation,
                        installDirectory: entry,
                        profileID: matchedProfileID
                    ))
                }
            }
        }
        return games
    }

    // MARK: - Install detection

    static func detectInstallation(in directory: URL, executableHint: String?) -> GameInstallation {
        GameInstallation(
            nativeApplication: findApplicationBundle(in: directory, depth: 2),
            windowsExecutable: findWindowsExecutable(in: directory, hint: executableHint)
        )
    }

    static func findApplicationBundle(in directory: URL, depth: Int) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let sorted = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let app = sorted.first(where: { $0.pathExtension == "app" }) { return app }
        guard depth > 0 else { return nil }
        for entry in sorted where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let app = findApplicationBundle(in: entry, depth: depth - 1) { return app }
        }
        return nil
    }

    /// Uses the profile's `executable` hint if it exists. Otherwise picks the largest `.exe` within
    /// `maxExecutableDepth` levels that is not an installer, redistributable, crash reporter or anti-cheat service.
    /// The game binary is almost always the biggest one.
    static func findWindowsExecutable(in directory: URL, hint: String?) -> URL? {
        let fm = FileManager.default
        if let hint {
            let hinted = directory.appending(path: hint)
            if fm.fileExists(atPath: hinted.path(percentEncoded: false)) { return hinted }
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var best: (url: URL, size: Int)?
        var visited = 0
        while let next = enumerator.nextObject() as? URL {
            visited += 1
            if visited > maxEnumeratedFiles { break }
            if enumerator.level > maxExecutableDepth {
                enumerator.skipDescendants()
                continue
            }
            guard next.pathExtension.lowercased() == "exe" else { continue }
            let name = next.lastPathComponent.lowercased()
            guard !excludedExecutableFragments.contains(where: { name.contains($0) }) else { continue }
            guard let values = try? next.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let size = values.fileSize ?? 0
            if size > (best?.size ?? -1) { best = (next, size) }
        }
        return best?.url
    }

    // MARK: - Helpers

    func profileID(matchingTitle title: String) -> String? {
        guard let catalog else { return nil }
        let wanted = GameItem.normalizedTitle(title)
        return catalog.allProfiles.first { GameItem.normalizedTitle($0.title) == wanted }?.id
    }

    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Merges entries for the same game across sources by normalized title. Steam wins (it has
    /// the app id for artwork and launch); missing install paths are filled in from the others.
    static func deduplicate(_ games: [GameItem]) -> [GameItem] {
        func priority(_ source: GameItem.Source) -> Int {
            switch source {
            case .steam: 0
            case .macApplication: 1
            case .customFolder: 2
            }
        }

        var order: [String] = []
        var byTitle: [String: GameItem] = [:]
        for game in games {
            let key = GameItem.normalizedTitle(game.title)
            guard !key.isEmpty else { continue }
            guard let existing = byTitle[key] else {
                byTitle[key] = game
                order.append(key)
                continue
            }
            let gameWins = priority(game.source) < priority(existing.source)
            var primary = gameWins ? game : existing
            let secondary = gameWins ? existing : game
            primary.installation.nativeApplication = primary.installation.nativeApplication ?? secondary.installation.nativeApplication
            primary.installation.windowsExecutable = primary.installation.windowsExecutable ?? secondary.installation.windowsExecutable
            primary.profileID = primary.profileID ?? secondary.profileID
            byTitle[key] = primary
        }
        return order.compactMap { byTitle[$0] }
    }
}
