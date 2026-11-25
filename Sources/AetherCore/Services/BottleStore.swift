import Foundation

/// A Wine prefix under `AetherPaths.bottles` (one per game by default).
public struct BottleInfo: Identifiable, Sendable, Hashable {
    /// Folder name; also what `GameItem.bottleName` refers to.
    public let id: String
    public let url: URL
    public let isInitialized: Bool

    public var driveC: URL { url.appending(path: "drive_c", directoryHint: .isDirectory) }
}

/// Lists, creates and deletes bottles. Sizes are computed on demand (it walks the whole prefix).
public enum BottleStore {
    public static func list(root: URL = AetherPaths.bottles) -> [BottleInfo] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { BottleInfo(id: $0.lastPathComponent, url: $0, isInitialized: WinePrefix.isInitialized($0)) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Creates an empty bottle folder (Wine initialises it on first run). Returns the existing one if taken.
    public static func create(named name: String, root: URL = AetherPaths.bottles) throws -> BottleInfo {
        let id = RuntimeInstaller.slugify(name)
        let url = root.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return BottleInfo(id: id, url: url, isInitialized: WinePrefix.isInitialized(url))
    }

    /// Deletes a bottle (refuses anything outside `root`).
    public static func delete(_ bottle: BottleInfo, root: URL = AetherPaths.bottles) throws {
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        guard bottle.url.standardizedFileURL.path(percentEncoded: false).hasPrefix(rootPath) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: bottle.url)
    }

    /// Total bytes on disk.
    public static func size(of bottle: BottleInfo) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: bottle.url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

/// A game the user added by hand, usually after running its installer inside a bottle.
public struct ManualGame: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var title: String
    public var executable: URL
    /// Bottle folder name the game was installed into (it must run there).
    public var bottle: String

    public init(id: String = UUID().uuidString, title: String, executable: URL, bottle: String) {
        self.id = id
        self.title = title
        self.executable = executable
        self.bottle = bottle
    }
}

/// `~/Library/Application Support/Aether/manual_games.json`
public enum ManualGameStore {
    public static var file: URL { AetherPaths.applicationSupport.appending(path: "manual_games.json") }

    public static func load(from url: URL = file) -> [ManualGame] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ManualGame].self, from: data)) ?? []
    }

    public static func save(_ games: [ManualGame], to url: URL = file) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(games).write(to: url, options: .atomic)
    }

    public static func add(_ game: ManualGame, to url: URL = file) throws {
        var games = load(from: url).filter { $0.executable != game.executable }
        games.append(game)
        try save(games, to: url)
    }

    public static func remove(id: String, from url: URL = file) throws {
        try save(load(from: url).filter { $0.id != id }, to: url)
    }
}
