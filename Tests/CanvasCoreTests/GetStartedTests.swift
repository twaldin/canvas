import Foundation
import Testing
@testable import CanvasCore

/// Help › Get Started: opens by itself for a new home until closed once, never for a home that
/// already had boards, and its walk-through advances only on what really happened to the tray.
@MainActor
struct GetStartedTests {
    /// An Easl home: `get-started.json` and the boards directory, as the app lays them out.
    struct Home {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("get-started-\(UUID().uuidString)", isDirectory: true)
        var store: GetStarted.Store { .init(url: root.appendingPathComponent("get-started.json")) }
        var boards: URL { root.appendingPathComponent("boards", isDirectory: true) }

        init(boards names: [String] = []) throws {
            try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
            for name in names { try Data("{}".utf8).write(to: boards.appendingPathComponent(name)) }
        }

        /// A launch that opens the initial board, which writes its board file.
        func launch() throws -> Bool {
            let opens = store.launch(boards: boards)
            try Data("{}".utf8).write(to: boards.appendingPathComponent("brd_home.json"))
            return opens
        }
    }

    @Test func aNewHomeGetsItUntilItIsClosed() throws {
        let home = try Home()
        #expect(try home.launch())
        // Quit with it still open (to install zmx, say): it's back, though the home has a board now.
        #expect(try home.launch())
        home.store.dismiss()
        #expect(try !home.launch())
        #expect(try !home.launch())
    }

    @Test func anExistingUsersHomeNeverGetsItByItself() throws {
        let home = try Home(boards: ["brd_repo.json"])
        #expect(try !home.launch())
        #expect(home.store.load() == GetStarted.State(dismissed: true))
    }

    @Test func archivesAndStrayFilesAreNotBoards() throws {
        let home = try Home(boards: [".DS_Store"])
        try FileManager.default.createDirectory(at: home.boards.appendingPathComponent("brd_x", isDirectory: true), withIntermediateDirectories: true)
        #expect(try home.launch())
    }

    @Test func anUnreadableStateFileCountsAsNone() throws {
        let fresh = try Home()
        try Data("not json".utf8).write(to: fresh.store.url)
        #expect(try fresh.launch())
        let used = try Home(boards: ["brd_repo.json"])
        try Data("not json".utf8).write(to: used.store.url)
        #expect(try !used.launch())
    }

    @Test func walkThroughFollowsTheTray() async throws {
        let board = Board(id: "b", root: URL(fileURLWithPath: "/tmp"))
        let note = board.create(type: .note, props: .object(["markdown": .string(GetStarted.practiceMarkdown)]))
        var guide = GetStarted.Progress(delivered: board.delivered, trayCount: board.tray.count)
        func observe() { guide.observe(trayCount: board.tray.count, delivered: board.delivered) }
        #expect(guide.step == .point(unstaged: false))

        let mention = try board.stage(.object(note.id))
        observe()
        #expect(guide.step == .send)
        // A second Hyper-click on it takes it back off: not sent, and the guide says why.
        try board.unstage(mention.id)
        observe()
        #expect(guide.step == .point(unstaged: true))

        try board.stage(.object(note.id))
        observe()
        _ = await board.drain(caller: nil)
        observe()
        #expect(guide.step == .done)
        // Staging again after sending leaves it done.
        try board.stage(.object(note.id))
        observe()
        #expect(guide.step == .done)
    }

    @Test func deletingTheStagedTileIsNotSending() throws {
        let board = Board(id: "b", root: URL(fileURLWithPath: "/tmp"))
        let note = board.create(type: .note, props: .object(["markdown": .string("x")]))
        try board.stage(.object(note.id))
        var guide = GetStarted.Progress(delivered: board.delivered, trayCount: board.tray.count)
        #expect(guide.step == .send)
        try board.delete(note.id)
        guide.observe(trayCount: board.tray.count, delivered: board.delivered)
        #expect(guide.step == .point(unstaged: true))
        #expect(board.delivered == 0)
    }

    /// Help › Get Started after a first mention was sent walks through it again from step 1.
    @Test func reopeningCountsFromNow() async throws {
        let board = Board(id: "b", root: URL(fileURLWithPath: "/tmp"))
        let note = board.create(type: .note, props: .object(["markdown": .string("x")]))
        try board.stage(.object(note.id))
        _ = await board.drain(caller: nil)
        #expect(board.delivered == 1)
        let reopened = GetStarted.Progress(delivered: board.delivered, trayCount: board.tray.count)
        #expect(reopened.step == .point(unstaged: false))
    }

    @Test func hyperVCommitCountsAsSent() async throws {
        let board = Board(id: "b", root: URL(fileURLWithPath: "/tmp"))
        let note = board.create(type: .note, props: .object(["markdown": .string("x")]))
        try board.stage(.object(note.id))
        var guide = GetStarted.Progress(delivered: board.delivered, trayCount: board.tray.count)
        // Hyper-V: peek, paste, then commit exactly what was pasted.
        let pasted = await board.drain(peek: true)
        #expect(board.delivered == 0)
        board.commit(pasted.mentions.map(\.id))
        guide.observe(trayCount: board.tray.count, delivered: board.delivered)
        #expect(guide.step == .done)
    }
}
