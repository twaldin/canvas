import Foundation
import Testing
import CanvasCore

@MainActor
struct BoardTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-tests-\(UUID().uuidString)")

    func makeBoard() -> Board {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Board(id: "brd_test", root: root)
    }

    @Test func peekDrainKeepsTrayUntilCommit() async throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("hypothesis")]))
        let mention = try board.stage(.object(note.id))

        let peeked = await board.drain(peek: true)
        #expect(peeked.mentions.map(\.id) == [mention.id])
        #expect(peeked.context.contains("hypothesis"))
        #expect(board.tray.count == 1, "a peek must not lose the mention if the prompt is cancelled")

        // A mention staged after the peek survives the commit of the peeked ids.
        let other = board.create(type: .note, props: .object(["markdown": .string("later")]))
        let late = try board.stage(.object(other.id))
        board.commit(peeked.mentions.map(\.id))
        #expect(board.tray.map(\.id) == [late.id])
    }

    @Test func emptyTrayDrainsToEmptyContext() async {
        let board = makeBoard()
        #expect(await board.drain().context == "")
    }

    @Test func stagedMentionsSurviveSaveAndReload() async throws {
        let store = BoardStore(directory: root.appendingPathComponent("boards"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = store.load(root: root)
        let note = board.create(type: .note, props: .object(["markdown": .string("keep me staged")]))
        let mention = try board.stage(.object(note.id))
        store.save(board)

        let reloaded = store.load(root: root)
        #expect(reloaded.tray.map(\.id) == [mention.id])
        #expect(await reloaded.drain().context.contains("keep me staged"))
    }

    @Test func deletingAnObjectRemovesItsMentions() throws {
        let board = makeBoard()
        let a = board.create(type: .shape, props: .object(["kind": .string("rect")]))
        let b = board.create(type: .shape, props: .object(["kind": .string("rect")]))
        try board.stage(.object(a.id))
        try board.stage(.group(objects: [a.id, b.id], name: nil))
        try board.stage(.object(b.id))
        try board.delete(a.id)
        #expect(board.tray.count == 1)
        #expect(board.tray.first?.target == .object(b.id))
    }

    @Test func editingAStagedObjectMarksItEditedButKeepsIt() async throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("v1")]))
        try board.stage(.object(note.id))
        try board.update(note.id, props: .object(["markdown": .string("v2")]))
        #expect(board.tray.count == 1)
        #expect(board.tray[0].edited)
        #expect(await board.drain().context.contains("(edited)"))
    }

    @Test func updateWithStaleRevConflicts() throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("v1")]))
        try board.update(note.id, rev: 1, props: .object(["markdown": .string("v2")]))
        #expect(throws: BoardError.self) { try board.update(note.id, rev: 1, props: .object(["markdown": .string("v3")])) }
    }

    @Test func agentObjectsPlaceBesideTheirTerminalWithoutOverlap() {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/"), "command": .array([])]), frame: Frame(x: 0, y: 0, w: 800, h: 500))
        let first = board.create(type: .note, props: .object(["markdown": .string("a")]), caller: terminal.id)
        let second = board.create(type: .note, props: .object(["markdown": .string("b")]), caller: terminal.id)
        #expect(first.frame.x >= terminal.frame.maxX)
        #expect(!first.frame.intersects(second.frame))
        #expect(first.createdBy == .agent(tile: terminal.id))
    }

    @Test func viewportPlacementSlidesPastTilesButNotDrawings() {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: -400, y: -250, w: 800, h: 500))
        let lasso = board.create(type: .shape, props: .object(["kind": .string("rect")]), frame: Frame(x: -2000, y: -2000, w: 4000, h: 4000))
        let first = board.create(type: .code, props: .object(["path": .string("a.swift")]))
        let second = board.create(type: .code, props: .object(["path": .string("b.swift")]))
        #expect(!first.frame.intersects(terminal.frame))
        #expect(!second.frame.intersects(first.frame) && !second.frame.intersects(terminal.frame))
        #expect(lasso.frame.contains(first.frame), "a user drawing around the area doesn't push tiles away")
    }

    @Test func idleAfterUnseenWorkIsDoneUntilSeen() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/"), "command": .array([])]))
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .idle, message: nil, seq: 2, source: "canvas-omp")
        #expect(board.objects[terminal.id]?.props["lifecycle"]?["state"]?.string == "done")
        board.markSeen(terminal.id)
        #expect(board.objects[terminal.id]?.props["lifecycle"]?["state"]?.string == "idle")
    }

    @Test func staleLifecycleSeqIsIgnored() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/"), "command": .array([])]))
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .blocked, message: "approve?", seq: 5, source: "canvas-omp")
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .working, message: nil, seq: 4, source: "canvas-omp")
        #expect(board.objects[terminal.id]?.props["lifecycle"]?["state"]?.string == "blocked")
    }

    @Test func followReusesOneTilePerTerminalAndIgnoresFilesOutsideTheProject() throws {
        let board = makeBoard()
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("follow-cwd-\(UUID().uuidString)")
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(worktree.path), "command": .array([])]))
        let first = try #require(try board.follow(tile: terminal.id, path: root.appendingPathComponent("src/a.ts").path, range: LineRange(start: 1, end: 10), action: "read"))
        let second = try #require(try board.follow(tile: terminal.id, path: "src/b.ts", range: nil, action: "edit"))
        #expect(first.id == second.id)
        #expect(board.objects.values.filter { $0.type == .code }.count == 1)
        #expect(second.props["path"]?.string == "src/b.ts")
        #expect(first.props["path"]?.string == "src/a.ts", "absolute paths under the root are stored relative")

        let inCwd = worktree.appendingPathComponent("lib/c.ts").path
        #expect(try board.follow(tile: terminal.id, path: inCwd, range: nil, action: "read")?.id == first.id, "the terminal's cwd counts as the project")
        #expect(try board.follow(tile: terminal.id, path: "/tmp/shot.png", range: nil, action: "read") == nil)
        #expect(try board.follow(tile: terminal.id, path: root.path + "-sibling/a.ts", range: nil, action: "read") == nil, "a name prefix is not containment")
        #expect(board.objects[first.id]?.props["path"]?.string == inCwd, "ignored reads leave the follow tile where it was")
    }

    @Test func codeMentionContextIncludesTheRealExcerpt() async throws {
        let board = makeBoard()
        let file = root.appendingPathComponent("restore.ts")
        try "line one\nexport function restoreSnapshot() {\n  return 1\n}\n".write(to: file, atomically: true, encoding: .utf8)
        let code = board.create(type: .code, props: .object(["path": .string("restore.ts")]))
        try board.stage(.code(object: code.id, path: "restore.ts", lines: LineRange(start: 2, end: 3), side: nil, symbol: "restoreSnapshot"))
        let context = await board.drain().context
        #expect(context.contains("restore.ts:2-3 (symbol restoreSnapshot)"))
        #expect(context.contains("  > 2    export function restoreSnapshot() {"))
        #expect(context.contains("  > 3      return 1"))
        #expect(context.contains("    1    line one"), "short mentions carry unmarked surrounding lines")

        let long = root.appendingPathComponent("long.txt")
        try (1...40).map { "row \($0)" }.joined(separator: "\n").write(to: long, atomically: true, encoding: .utf8)
        let tile = board.create(type: .code, props: .object(["path": .string("long.txt")]))
        try board.stage(.code(object: tile.id, path: "long.txt", lines: LineRange(start: 5, end: 30), side: nil, symbol: nil))
        let capped = await board.drain().context
        #expect(capped.contains("  > 16   row 16"))
        #expect(!capped.contains("row 17") && !capped.contains("row 4\n"), "long ranges cap at 12 lines with no extra context")
        #expect(capped.contains("    …"))
    }

    @Test func drawnShapeMentionDescribesWhatItEnclosesAndWhatItIsDrawnOn() async throws {
        let board = makeBoard()
        let inner = board.create(type: .note, props: .object(["markdown": .string("inside")]), frame: Frame(x: 20, y: 20, w: 50, h: 50))
        let box = board.create(type: .shape, props: .object(["kind": .string("rect"), "text": .string("auth path?")]), frame: Frame(x: 0, y: 0, w: 200, h: 200))
        try board.stage(.object(box.id))
        let context = await board.drain().context
        #expect(context.contains("drawn by user"))
        #expect(context.contains("encloses \(inner.id)"))
        #expect(!context.contains("· over"), "nothing lies under the box")

        let page = board.create(type: .browser, props: .object(["url": .string("http://localhost/")]), frame: Frame(x: 1000, y: 0, w: 600, h: 400))
        let upper = board.create(type: .browser, props: .object(["url": .string("http://localhost/b")]), frame: Frame(x: 1000, y: 0, w: 600, h: 400))
        let circle = board.create(type: .shape, props: .object(["kind": .string("ellipse")]), frame: Frame(x: 1240, y: 226, w: 125, h: 120))
        let straddling = board.create(type: .shape, props: .object(["kind": .string("rect")]), frame: Frame(x: 1500, y: 300, w: 200, h: 50))
        try board.stage(.object(circle.id))
        try board.stage(.object(straddling.id))
        let over = await board.drain().context
        #expect(over.contains("\(circle.id) \"ellipse\" (drawn by user) · over browser \(upper.id) at (240, 200) 125×120"), "the topmost containing tile, in its local units (below its title bar)")
        #expect(!over.contains(page.id))
        #expect(!over.contains("\(straddling.id) \"rect\" (drawn by user) · over"), "a box that only partly covers a tile isn't drawn on it")

        // On a tile at 2×, the same spot is half as many of the tile's own points in, below a title bar twice as tall.
        let scaled = board.create(type: .browser, props: .object(["url": .string("http://localhost/c"), "scale": .number(2)]), frame: Frame(x: 3000, y: 0, w: 1200, h: 800))
        let mark = board.create(type: .shape, props: .object(["kind": .string("ellipse")]), frame: Frame(x: 3480, y: 452, w: 250, h: 240))
        try board.stage(.object(mark.id))
        let onScaled = await board.drain().context
        #expect(onScaled.contains("\(mark.id) \"ellipse\" (drawn by user) · over browser \(scaled.id) at (240, 200) 125×120"))
    }

    @Test func boardsSavedBeforeFormat2GrowTileFramesByTheTitleBarOnce() throws {
        // Format 1 stored a tile's body; its 26 pt title bar drew above it. Shapes were exact.
        let legacy = """
        {"id":"brd_old","root":"/tmp","revision":3,"objects":[
          {"id":"obj_code","type":"code","frame":{"x":10,"y":20,"w":640,"h":240},"z":1,"rev":1,"createdBy":{"kind":"user"},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","props":{"path":"a.swift"}},
          {"id":"obj_note","type":"note","frame":{"x":700,"y":20,"w":280,"h":240},"z":2,"rev":1,"createdBy":{"kind":"user"},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","props":{"markdown":"n"}},
          {"id":"obj_box","type":"shape","frame":{"x":0,"y":400,"w":100,"h":50},"z":3,"rev":1,"createdBy":{"kind":"user"},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","props":{"kind":"rect"}},
          {"id":"obj_lane","type":"group","frame":{"x":0,"y":0,"w":0,"h":0},"z":4,"rev":1,"createdBy":{"kind":"user"},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","props":{"members":["obj_code"],"padding":24}}
        ]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(BoardSnapshot.self, from: Data(legacy.utf8))
        #expect(snapshot.format == nil)
        let board = Board(snapshot: snapshot)
        #expect(try board.object("obj_code").frame == Frame(x: 10, y: 20, w: 640, h: 266), "the same box on screen, now all of it")
        #expect(try board.object("obj_note").frame.h == 266)
        #expect(try board.object("obj_box").frame == Frame(x: 0, y: 400, w: 100, h: 50), "shapes were already their drawn box")
        let lane = try board.object("obj_lane").frame
        #expect(lane.maxY == 20 + 266 + 24, "groups wrap the migrated tile, bottom padding intact")

        let saved = board.snapshot
        #expect(saved.format == Board.format)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reloaded = Board(snapshot: try decoder.decode(BoardSnapshot.self, from: try encoder.encode(saved)))
        #expect(try reloaded.object("obj_code").frame.h == 266, "a format-2 board loads as saved")
    }
}
