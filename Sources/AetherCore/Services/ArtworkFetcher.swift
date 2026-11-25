import Foundation

public enum ArtworkKind: String, Sendable, CaseIterable, Hashable {
    /// 600×900 portrait cover for grid cards.
    case grid
    /// Wide background for the hero banner.
    case hero
    /// Transparent title logo.
    case logo

    var steamGridDBPath: String {
        switch self {
        case .grid: "grids"
        case .hero: "heroes"
        case .logo: "logos"
        }
    }

    var steamGridDBQuery: [URLQueryItem] {
        var items = [URLQueryItem(name: "nsfw", value: "false"), URLQueryItem(name: "humor", value: "false")]
        if self == .grid { items.append(URLQueryItem(name: "dimensions", value: "600x900")) }
        return items
    }

    /// Public Steam CDN asset names. No API key needed; only works for Steam app ids.
    var steamCDNFile: String {
        switch self {
        case .grid: "library_600x900_2x.jpg"
        case .hero: "library_hero.jpg"
        case .logo: "logo.png"
        }
    }
}

/// Downloads cover, hero and logo art and caches it on disk. Returns **file URLs only**.
/// Decoding happens later in the UI, at display size. Nothing here keeps image bytes in memory.
///
/// Lookup order for each image:
/// 1. Disk cache (`~/Library/Caches/Aether/Artwork/<key>.img`)
/// 2. SteamGridDB API v2, if an API key is configured (by Steam app id, else title search)
/// 3. Steam's public CDN, for Steam games
/// A miss is remembered for 7 days so the API is not hit again on every launch.
public actor ArtworkFetcher {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let urlSessionTransport: Transport = { request in
        try await URLSession.shared.data(for: request)
    }

    static let steamGridDBBase = URL(string: "https://www.steamgriddb.com/api/v2")!
    static let steamCDNBase = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps")!
    static let missRetryInterval: TimeInterval = 7 * 24 * 60 * 60

    private let apiKey: String?
    private let cacheDirectory: URL
    private let transport: Transport
    private var inFlight: [String: Task<URL?, Never>] = [:]

    public init(
        apiKey: String?,
        cacheDirectory: URL = AetherPaths.artworkCache,
        transport: @escaping Transport = ArtworkFetcher.urlSessionTransport
    ) {
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.cacheDirectory = cacheDirectory
        self.transport = transport
    }

    /// Local file URL of the requested art, downloading it if needed. `nil` if none exists.
    public func artwork(_ kind: ArtworkKind, for game: GameItem) async -> URL? {
        let key = Self.cacheKey(kind, for: game)
        let file = cacheDirectory.appending(path: "\(key).img")
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        if isRecentMiss(key) { return nil }

        // Coalesce: 20 cards appearing at once must not fire 20 identical requests.
        if let running = inFlight[key] { return await running.value }
        let task = Task { await self.download(kind, for: game, key: key, to: file) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Deletes all cached artwork (Settings → "Clear artwork cache").
    public func purgeDiskCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: - Internals

    static func cacheKey(_ kind: ArtworkKind, for game: GameItem) -> String {
        if let appID = game.steamAppID { return "steam-\(appID)-\(kind.rawValue)" }
        return "title-\(GameItem.normalizedTitle(game.title))-\(kind.rawValue)"
    }

    private func download(_ kind: ArtworkKind, for game: GameItem, key: String, to file: URL) async -> URL? {
        var candidates: [URL] = []
        if let apiKey {
            candidates += await steamGridDBCandidates(kind, for: game, apiKey: apiKey)
        }
        if let appID = game.steamAppID {
            candidates.append(Self.steamCDNBase.appending(path: "\(appID)/\(kind.steamCDNFile)"))
        }

        for candidate in candidates {
            guard let data = try? await fetch(URLRequest(url: candidate)), Self.looksLikeImage(data) else { continue }
            do {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                return file
            } catch {
                return nil // Disk full or permissions. Do not record a miss; retry next launch.
            }
        }
        recordMiss(key)
        return nil
    }

    private func steamGridDBCandidates(_ kind: ArtworkKind, for game: GameItem, apiKey: String) async -> [URL] {
        let gameSegment: String
        if let appID = game.steamAppID {
            gameSegment = "steam/\(appID)"
        } else if let gameID = await searchSteamGridDBGameID(title: game.title, apiKey: apiKey) {
            gameSegment = "game/\(gameID)"
        } else {
            return []
        }

        let endpoint = Self.steamGridDBBase.appending(path: "\(kind.steamGridDBPath)/\(gameSegment)")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return [] }
        components.queryItems = kind.steamGridDBQuery
        guard let url = components.url,
              let data = try? await fetch(Self.authorized(url, apiKey: apiKey)),
              let response = try? JSONDecoder().decode(SGDBResponse<[SGDBImage]>.self, from: data),
              response.success
        else { return [] }

        // Results are ranked by community score. Keep a couple of fallbacks in case a CDN link is dead.
        return (response.data ?? []).prefix(3).compactMap { URL(string: $0.url) }
    }

    private func searchSteamGridDBGameID(title: String, apiKey: String) async -> Int? {
        let term = title.replacingOccurrences(of: "/", with: " ")
        let url = Self.steamGridDBBase.appending(path: "search/autocomplete").appending(path: term)
        guard let data = try? await fetch(Self.authorized(url, apiKey: apiKey)),
              let response = try? JSONDecoder().decode(SGDBResponse<[SGDBGame]>.self, from: data)
        else { return nil }
        return response.data?.first?.id
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func authorized(_ url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    /// PNG, JPEG, WebP or GIF magic bytes. Rejects HTML error pages served with a 200.
    static func looksLikeImage(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 4 else { return false }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }   // PNG
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return true }         // JPEG
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }   // GIF8
        if b.count >= 12, b.starts(with: [0x52, 0x49, 0x46, 0x46]),   // RIFF....WEBP
           Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return true }
        return false
    }

    private func missMarker(_ key: String) -> URL {
        cacheDirectory.appending(path: "\(key).miss")
    }

    private func isRecentMiss(_ key: String) -> Bool {
        let path = missMarker(key).path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(modified) < Self.missRetryInterval
    }

    private func recordMiss(_ key: String) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? Data().write(to: missMarker(key), options: .atomic)
    }
}

// MARK: - SteamGridDB wire format

private struct SGDBResponse<Payload: Decodable>: Decodable {
    let success: Bool
    let data: Payload?
}

private struct SGDBImage: Decodable {
    let url: String
}

private struct SGDBGame: Decodable {
    let id: Int
}
