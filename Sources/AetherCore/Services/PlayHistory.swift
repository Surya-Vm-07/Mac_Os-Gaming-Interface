import Foundation

public struct PlayRecord: Codable, Sendable, Equatable {
    public var lastPlayed: Date
    public var launches: Int
    /// Only measured for sessions Aether supervises (Wine). Native games report launches only.
    public var secondsPlayed: Double

    public init(lastPlayed: Date, launches: Int = 0, secondsPlayed: Double = 0) {
        self.lastPlayed = lastPlayed
        self.launches = launches
        self.secondsPlayed = secondsPlayed
    }
}

/// Last-played, launch counts and playtime, stored as a small JSON file in Application Support.
public struct PlayHistory: Codable, Sendable, Equatable {
    public private(set) var records: [String: PlayRecord] = [:]

    public init() {}

    public func record(for gameID: String) -> PlayRecord? {
        records[gameID]
    }

    public mutating func recordLaunch(_ gameID: String, at date: Date = Date()) {
        var record = records[gameID] ?? PlayRecord(lastPlayed: date)
        record.lastPlayed = date
        record.launches += 1
        records[gameID] = record
    }

    public mutating func recordSession(_ gameID: String, duration: TimeInterval, endedAt date: Date = Date()) {
        var record = records[gameID] ?? PlayRecord(lastPlayed: date)
        record.secondsPlayed += max(duration, 0)
        record.lastPlayed = date
        records[gameID] = record
    }

    /// Most recently played first.
    public func recentGameIDs(limit: Int) -> [String] {
        records
            .sorted { $0.value.lastPlayed > $1.value.lastPlayed }
            .prefix(max(limit, 0))
            .map(\.key)
    }

    /// Missing or corrupt files give an empty history. Play history is never worth a crash.
    public static func load(from url: URL = AetherPaths.playHistory) -> PlayHistory {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder.aether.decode(PlayHistory.self, from: data)
        else { return PlayHistory() }
        return history
    }

    public func save(to url: URL = AetherPaths.playHistory) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.aether.encode(self).write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    /// Fresh encoder per call: JSONEncoder is a mutable class and not Sendable.
    static var aether: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var aether: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
