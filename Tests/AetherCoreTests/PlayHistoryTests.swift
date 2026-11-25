import Foundation
import Testing
@testable import AetherCore

@Suite("PlayHistory")
struct PlayHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Launches, sessions and recency ordering")
    func recording() {
        var history = PlayHistory()
        history.recordLaunch("a", at: t0)
        history.recordLaunch("b", at: t0.addingTimeInterval(60))
        history.recordLaunch("a", at: t0.addingTimeInterval(120))
        history.recordSession("a", duration: 3600, endedAt: t0.addingTimeInterval(3720))

        #expect(history.record(for: "a")?.launches == 2)
        #expect(history.record(for: "a")?.secondsPlayed == 3600)
        #expect(history.recentGameIDs(limit: 5) == ["a", "b"])
        #expect(history.recentGameIDs(limit: 1) == ["a"])
        #expect(history.record(for: "missing") == nil)
    }

    @Test("Save → load round trip; a corrupt file loads as empty")
    func persistence() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aether-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "play_history.json")

        var history = PlayHistory()
        history.recordLaunch("steam:400", at: t0)
        try history.save(to: file)
        #expect(PlayHistory.load(from: file) == history)

        try Data("{ broken".utf8).write(to: file)
        #expect(PlayHistory.load(from: file) == PlayHistory())
    }
}

@Suite("CloudService")
struct CloudServiceTests {
    @Test("Every service has an https web client and user-facing copy")
    func catalog() {
        for service in CloudService.allCases {
            #expect(service.webURL.scheme == "https")
            #expect(!service.displayName.isEmpty)
            #expect(!service.requirement.isEmpty)
        }
        #expect(CloudService.xboxCloud.nativeAppURL == nil)
    }
}
