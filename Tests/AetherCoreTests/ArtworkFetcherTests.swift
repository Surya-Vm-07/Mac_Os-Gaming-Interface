import Foundation
import Synchronization
import Testing
@testable import AetherCore

/// Records requests and serves canned responses keyed by URL substring. No network.
final class StubTransport: Sendable {
    private let log = Mutex<[URLRequest]>([])
    private let routes: [(String, Int, Data)]

    init(_ routes: [(match: String, status: Int, body: Data)]) {
        self.routes = routes.map { ($0.match, $0.status, $0.body) }
    }

    var requests: [URLRequest] { log.withLock { $0 } }

    var transport: ArtworkFetcher.Transport {
        { [self] request in
            log.withLock { $0.append(request) }
            let url = request.url?.absoluteString ?? ""
            guard let route = routes.first(where: { url.contains($0.0) }) else {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            return (route.2, HTTPURLResponse(url: request.url!, statusCode: route.1, httpVersion: nil, headerFields: nil)!)
        }
    }
}

@Suite("ArtworkFetcher")
struct ArtworkFetcherTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
    static let steamGame = GameItem(id: "steam:1091500", title: "Cyberpunk 2077", source: .steam(appID: "1091500"),
                                    installation: GameInstallation())

    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "aether-art-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("SteamGridDB by Steam id: authorized request, cached to disk, second call is free")
    func steamGridDBHappyPath() async throws {
        let cache = tempDir()
        defer { try? FileManager.default.removeItem(at: cache) }
        let stub = StubTransport([
            ("grids/steam/1091500", 200, Data(#"{"success":true,"data":[{"url":"https://cdn2.steamgriddb.com/grid/abc.png"}]}"#.utf8)),
            ("cdn2.steamgriddb.com/grid/abc.png", 200, Self.png),
        ])
        let fetcher = ArtworkFetcher(apiKey: "test-key", cacheDirectory: cache, transport: stub.transport)

        let file = try #require(await fetcher.artwork(.grid, for: Self.steamGame))
        #expect(try Data(contentsOf: file) == Self.png)

        let api = try #require(stub.requests.first)
        #expect(api.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(api.url?.query?.contains("dimensions=600x900") == true)

        let before = stub.requests.count
        #expect(await fetcher.artwork(.grid, for: Self.steamGame) == file)
        #expect(stub.requests.count == before)
    }

    @Test("No API key: falls back to the public Steam CDN")
    func steamCDNFallback() async throws {
        let cache = tempDir()
        defer { try? FileManager.default.removeItem(at: cache) }
        let stub = StubTransport([("steam/apps/1091500/library_hero.jpg", 200, Self.png)])
        let fetcher = ArtworkFetcher(apiKey: nil, cacheDirectory: cache, transport: stub.transport)

        #expect(await fetcher.artwork(.hero, for: Self.steamGame) != nil)
        #expect(stub.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test("HTML error page served as 200 is rejected; misses are remembered")
    func rejectsNonImagesAndRemembersMisses() async throws {
        let cache = tempDir()
        defer { try? FileManager.default.removeItem(at: cache) }
        let stub = StubTransport([("steam/apps", 200, Data("<html>nope</html>".utf8))])
        let fetcher = ArtworkFetcher(apiKey: nil, cacheDirectory: cache, transport: stub.transport)

        #expect(await fetcher.artwork(.grid, for: Self.steamGame) == nil)
        let before = stub.requests.count
        #expect(await fetcher.artwork(.grid, for: Self.steamGame) == nil)
        #expect(stub.requests.count == before)
    }

    @Test("Non-Steam game: title search, then grids by SteamGridDB game id")
    func titleSearch() async throws {
        let cache = tempDir()
        defer { try? FileManager.default.removeItem(at: cache) }
        let stub = StubTransport([
            ("search/autocomplete", 200, Data(#"{"success":true,"data":[{"id":42,"name":"Hades"}]}"#.utf8)),
            ("grids/game/42", 200, Data(#"{"success":true,"data":[{"url":"https://cdn2.steamgriddb.com/grid/h.png"}]}"#.utf8)),
            ("grid/h.png", 200, Self.png),
        ])
        let game = GameItem(id: "custom:/g/Hades", title: "Hades", source: .customFolder, installation: GameInstallation())
        let fetcher = ArtworkFetcher(apiKey: "k", cacheDirectory: cache, transport: stub.transport)

        #expect(await fetcher.artwork(.grid, for: game) != nil)
        #expect(ArtworkFetcher.cacheKey(.grid, for: game) == "title-hades-grid")
    }
}
