import Foundation
import Testing
import CanvasCore

@MainActor
struct UndoTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-undo-\(UUID().uuidString)")

    func makeBoard() -> Board {
        Board(id: "brd_test", root: root)
    }

    func terminal(on board: Board) -> CanvasObject {
        board.create(type: .terminal, props: .object(["cwd": .string(root.path), "command": .array([])]), frame: Frame(x: 0, y: 0, w: 800, h: 500))
    }

    @Test func userUndoesAnAgentsEdit() throws {
        let board = makeBoard()
        let agent = terminal(on: board)
        let note = board.create(type: .note, props: .object(["markdown": .string("mine")]), frame: Frame(x: 900, y: 0, w: 320, h: 200))
        try board.update(note.id, props: .object(["markdown": .string("rewritten by agent")]), caller: agent.id)

        #expect(board.undo())
        let restored = try board.object(note.id)
        #expect(restored.props["markdown"]?.string == "mine")
        #expect(restored.rev > 2, "undo is a new revision, so an agent holding rev 2 gets a conflict")
        #expect(throws: BoardError.self) { try board.update(note.id, rev: 2, props: .object(["markdown": .string("stale")]), caller: agent.id) }

        #expect(board.redo())
        #expect(try board.object(note.id).props["markdown"]?.string == "rewritten by agent")
    }

    @Test func undoingADeleteRestoresTheSameObjectAndStacking() throws {
        let board = makeBoard()
        let bottom = board.create(type: .note, props: .object(["markdown": .string("bottom")]))
        let middle = board.create(type: .code, props: .object(["path": .string("a.swift")]))
        _ = board.create(type: .note, props: .object(["markdown": .string("top")]))
        var events: [String] = []
        board.onEvent = { events.append($0.name) }

        try board.delete(middle.id)
        #expect(board.objects[middle.id] == nil)
        board.undo()

        let restored = try board.object(middle.id)
        #expect(restored.z == middle.z)
        #expect(restored.z > bottom.z)
        #expect(restored.frame == middle.frame)
        #expect(restored.props == middle.props)
        #expect(events == ["object.deleted", "object.created"], "the UI re-creates the tile from the ordinary created event")
    }

    @Test func undoingACreateRemovesItAndRedoBringsItBack() throws {
        let board = makeBoard()
        let agent = terminal(on: board)
        let created = board.create(type: .html, props: .object(["html": .string("<p>hi</p>")]), caller: agent.id)
        try board.stage(.object(created.id))

        board.undo()
        #expect(board.objects[created.id] == nil)
        #expect(board.tray.isEmpty, "an undone object takes its staged mentions with it, like any delete")

        board.redo()
        #expect(try board.object(created.id).props["html"]?.string == "<p>hi</p>")
    }

    @Test func transactionIsOneStep() throws {
        let board = makeBoard()
        let a = board.create(type: .note, props: .object([:]), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        let b = board.create(type: .note, props: .object([:]), frame: Frame(x: 200, y: 0, w: 100, h: 100))
        let group = board.create(type: .group, props: .object(["members": .array([.string(a.id), .string(b.id)])]))

        // Move both, then ungroup, as one gesture.
        board.transaction {
            _ = try? board.update(a.id, frame: Frame(x: 50, y: 50, w: 100, h: 100))
            _ = try? board.update(b.id, frame: Frame(x: 250, y: 50, w: 100, h: 100))
            try? board.delete(group.id)
        }

        #expect(board.undo())
        #expect(try board.object(a.id).frame.x == 0)
        #expect(try board.object(b.id).frame.x == 200)
        #expect(board.objects[group.id] != nil)
        // The step before the gesture is the group's creation.
        #expect(board.undo())
        #expect(board.objects[group.id] == nil)
        #expect(board.objects[a.id] != nil)
    }

    @Test func nestedTransactionsCloseOnceAndEmptyOnesRecordNothing() throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("v1")]))
        board.transaction {
            board.transaction { _ = try? board.update(note.id, props: .object(["markdown": .string("v2")])) }
            _ = try? board.update(note.id, props: .object(["markdown": .string("v3")]))
        }
        board.transaction {}

        board.undo()
        #expect(try board.object(note.id).props["markdown"]?.string == "v1")
    }

    @Test func terminalBookkeepingIsNeitherRecordedNorRewound() throws {
        let board = makeBoard()
        let agent = terminal(on: board)
        let note = board.create(type: .note, props: .object(["markdown": .string("x")]))
        try board.update(agent.id, frame: Frame(x: 40, y: 40, w: 800, h: 500))
        try board.reportLifecycle(tile: agent.id, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        try board.reportSession(tile: agent.id, kind: "omp", sessionId: "s1", sessionPath: nil)
        try board.update(agent.id, props: .object(["title": .string("omp: fixing tests")]), caller: agent.id)

        // ⌘Z skips the bookkeeping and reverts the move, leaving lifecycle and session intact.
        board.undo()
        let reverted = try board.object(agent.id)
        #expect(reverted.frame.x == 0)
        #expect(reverted.props["lifecycle"]?["state"]?.string == "working")
        #expect(reverted.props["agent"]?["sessionId"]?.string == "s1")
        #expect(reverted.props["title"]?.string == "omp: fixing tests")
        #expect(board.objects[note.id] != nil)
    }

    @Test func aNewChangeAfterUndoDropsTheRedoBranch() throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("a")]))
        try board.update(note.id, props: .object(["markdown": .string("b")]))
        board.undo()
        #expect(board.history.canRedo)
        try board.update(note.id, props: .object(["markdown": .string("c")]))
        #expect(!board.history.canRedo)
        #expect(!board.redo())
    }

    @Test func zOrderChangesAreUndoable() throws {
        let board = makeBoard()
        let back = board.create(type: .note, props: .object([:]))
        let front = board.create(type: .note, props: .object([:]))
        try board.update(back.id, z: front.z + 1)
        board.undo()
        #expect(try board.object(back.id).z < board.object(front.id).z)
    }

    @Test func recreatedObjectsNeverReuseARevision() throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("v1")]))
        try board.update(note.id, props: .object(["markdown": .string("v2")]))
        board.undo()
        var highest = try board.object(note.id).rev
        #expect(highest == 3)

        // Undo the create, then redo it, several times: each incarnation is newer than the last.
        for _ in 0..<3 {
            board.undo()
            #expect(board.objects[note.id] == nil)
            board.redo()
            let rev = try board.object(note.id).rev
            #expect(rev > highest)
            highest = rev
        }
        #expect(throws: BoardError.self, "a writer still holding rev 2 must conflict") {
            try board.update(note.id, rev: 2, props: .object(["markdown": .string("stale")]))
        }
    }

    @Test func undoingATerminalsCreationKeepsItsLatestBookkeepingForRedo() throws {
        let board = makeBoard()
        let agent = terminal(on: board)
        try board.reportSession(tile: agent.id, kind: "omp", sessionId: "s-42", sessionPath: "/tmp/s-42.jsonl")
        try board.reportLifecycle(tile: agent.id, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        try board.update(agent.id, props: .object(["title": .string("omp: refactor")]), caller: agent.id)

        board.undo()
        #expect(board.objects[agent.id] == nil)
        board.redo()
        let back = try board.object(agent.id)
        #expect(back.props["agent"]?["sessionId"]?.string == "s-42", "resume metadata survives undo/redo")
        #expect(back.props["lifecycle"]?["state"]?.string == "working")
        #expect(back.props["title"]?.string == "omp: refactor")

        // Same for redoing a delete after the restored terminal reports again.
        try board.delete(agent.id)
        board.undo()
        try board.reportSession(tile: agent.id, kind: "omp", sessionId: "s-43", sessionPath: nil)
        board.redo()
        board.undo()
        #expect(try board.object(agent.id).props["agent"]?["sessionId"]?.string == "s-43")
    }

    @Test func historyIsBounded() throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["n": .number(0)]))
        for n in 1...(board.history.limit + 20) {
            try board.update(note.id, props: .object(["n": .number(Double(n))]))
        }
        var undone = 0
        while board.undo() { undone += 1 }
        #expect(undone == board.history.limit)
        #expect(board.objects[note.id] != nil, "the oldest steps (including the create) fell off the end")
    }
}

struct LassoTests {
    /// A "U" shape: two prongs joined at the bottom, open at the top middle.
    let horseshoe = Lasso(points: [(0, 0), (100, 0), (100, 100), (200, 100), (200, 0), (300, 0), (300, 300), (0, 300)])

    @Test func selectsOnlyFramesWhollyInside() {
        #expect(horseshoe.contains(Frame(x: 10, y: 10, w: 50, h: 50)))
        #expect(horseshoe.contains(Frame(x: 20, y: 150, w: 260, h: 100)))
        #expect(!horseshoe.contains(Frame(x: -10, y: 10, w: 50, h: 50)), "overlapping the outline is not enough")
        #expect(!horseshoe.contains(Frame(x: 400, y: 400, w: 10, h: 10)))
    }

    @Test func concaveNotchBetweenCornersRejectsTheFrame() {
        // All four corners are inside the U, but the notch cuts through the middle.
        #expect(!horseshoe.contains(Frame(x: 50, y: 50, w: 200, h: 100)))
    }

    @Test func degenerateLassoSelectsNothing() {
        #expect(!Lasso(points: [(0, 0), (100, 100)]).contains(Frame(x: 10, y: 10, w: 1, h: 1)))
    }
}
