import Foundation
import Testing
@testable import AetherCore

@Suite("BottleStore & manual games")
struct BottleStoreTests {
    @Test("Create, list, size, delete; deletion outside the root is refused")
    func lifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "aether-bottles-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let bottle = try BottleStore.create(named: "My Installers!", root: root)
        #expect(bottle.id == "my-installers")
        #expect(!bottle.isInitialized)
        try FileManager.default.createDirectory(at: bottle.url.appending(path: "drive_c/windows/system32"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: bottle.url.appending(path: "drive_c/file.bin"))

        let listed = BottleStore.list(root: root)
        #expect(listed.map(\.id) == ["my-installers"])
        #expect(listed.first?.isInitialized == true)
        #expect(BottleStore.size(of: listed[0]) >= 4096)

        let outsider = BottleInfo(id: "x", url: FileManager.default.temporaryDirectory, isInitialized: false)
        #expect(throws: (any Error).self) { try BottleStore.delete(outsider, root: root) }
        try BottleStore.delete(listed[0], root: root)
        #expect(BottleStore.list(root: root).isEmpty)
    }

    @Test("Manual games persist, dedupe by executable, and scan into the library with their bottle")
    func manualGames() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aether-manual-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "manual_games.json")
        let exe = dir.appending(path: "Game/Game.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)

        try ManualGameStore.add(ManualGame(title: "Old Name", executable: exe, bottle: "installers"), to: file)
        try ManualGameStore.add(ManualGame(title: "Game", executable: exe, bottle: "installers"), to: file)
        let stored = ManualGameStore.load(from: file)
        #expect(stored.count == 1)
        #expect(stored.first?.title == "Game")

        let scanner = LibraryScanner(configuration: .init(steamRoots: [], applicationDirectories: [], manualGames: stored))
        let game = try #require(scanner.scan().games.first)
        #expect(game.bottleName == "installers")
        #expect(game.installation.windowsExecutable == exe)

        try ManualGameStore.remove(id: stored[0].id, from: file)
        #expect(ManualGameStore.load(from: file).isEmpty)
    }
}
