import Foundation
import Testing
import CanvasCore

/// Edit › Mention (⇧⌘M) and agent.prompt's check of what the typing would reach.
@MainActor
struct KeyboardMentionTests {
    @Test func mentionTakesTheKeyboardTilesCurrentThingThenTheSelection() {
        let board = Board(id: "b", root: URL(fileURLWithPath: "/tmp"))
        let code = board.create(type: .code, props: .object(["path": "a.swift"]), frame: Frame(x: 400, y: 0, w: 300, h: 200))
        let note = board.create(type: .note, props: .object(["markdown": "x"]), frame: Frame(x: 0, y: 0, w: 300, h: 200))
        let terminal = board.create(type: .terminal, props: .object(["cwd": "/"]), frame: Frame(x: 0, y: 300, w: 300, h: 200))
        let lines = MentionTarget.code(object: code.id, path: "a.swift", lines: LineRange(start: 3, end: 9))
        func target(keyboard: ObjectID? = nil, _ selection: Set<ObjectID>, current: MentionTarget? = nil) -> MentionTarget? {
            KeyboardMention.target(keyboardTile: keyboard, selection: selection, current: current, on: board)
        }
        #expect(target(keyboard: code.id, [note.id], current: lines) == lines, "the tile with the keyboard wins over the selection")
        #expect(target(keyboard: terminal.id, [note.id]) == .object(terminal.id), "nothing picked in it: the tile itself")
        #expect(target([code.id], current: lines) == lines, "one selected tile's sub-selection")
        #expect(target([note.id]) == .object(note.id))
        #expect(target([code.id, terminal.id, note.id]) == .group(objects: [note.id, code.id, terminal.id], name: nil), "several: one group, in reading order")
        #expect(target([]) == nil)
        #expect(target(keyboard: "gone", []) == nil, "a tile that closed meanwhile")
        // A stroke of a sketch brings the whole sketch, as a Hyper-click on it does.
        let box = board.create(type: .shape, props: .object(["kind": "rect"]), frame: Frame(x: 0, y: 600, w: 50, h: 50))
        let label = board.create(type: .shape, props: .object(["kind": "text", "text": "slow"]), frame: Frame(x: 60, y: 600, w: 50, h: 20))
        board.create(type: .group, props: .object(["members": [.string(box.id), .string(label.id)], "title": "hot path"]))
        #expect(target([box.id]) == .group(objects: [box.id, label.id], name: "hot path"))
    }

    @Test func goToSelectsTheLinesItShowedSoMentionStagesThemNotTheWholeTile() {
        // ⌘P "forecast.py:9", or the "src/cart.ts · L10–19" row, then ⇧⌘M staged the whole tile.
        let board = Board(id: "b", root: URL(fileURLWithPath: "/tmp"))
        let shown = board.create(type: .code, props: .object(["path": "forecast.py", "range": LineRange(start: 4, end: 9).json]), frame: Frame(x: 0, y: 0, w: 300, h: 200))
        let whole = board.create(type: .code, props: .object(["path": "cart.ts"]), frame: Frame(x: 400, y: 0, w: 300, h: 200))
        let note = board.create(type: .note, props: .object(["markdown": "x"]), frame: Frame(x: 0, y: 300, w: 300, h: 200))
        #expect(KeyboardMention.goToLines(LineRange(start: 9, end: 9), landedOn: shown) == LineRange(start: 9, end: 9),
                "path:line on a tile already showing it: that line, not the tile's 4–9")
        #expect(KeyboardMention.goToLines(nil, landedOn: shown) == LineRange(start: 4, end: 9), "a code tile's row: the range it showed")
        #expect(KeyboardMention.goToLines(nil, landedOn: whole) == nil, "a whole file: the tile")
        #expect(KeyboardMention.goToLines(LineRange(start: 2, end: 2), landedOn: note) == nil)
        #expect(KeyboardMention.goToLines(nil, landedOn: nil) == nil)
    }

    @Test func promptSeesWhenTheForegroundProgramIsNotTheAgent() {
        #expect(PromptTarget.foreignProgram(kind: "omp", program: "tmux") == "tmux")
        #expect(PromptTarget.foreignProgram(kind: "omp", program: "nvim src/walk.rs") == "nvim src/walk.rs")
        #expect(PromptTarget.foreignProgram(kind: "claude", program: "less") == "less")
        #expect(PromptTarget.foreignProgram(kind: "omp", program: "omp") == nil)
        #expect(PromptTarget.foreignProgram(kind: "codex", program: "codex resume") == nil)
        #expect(PromptTarget.foreignProgram(kind: "gemini", program: "gemini.js") == nil, "an interpreter's script")
        #expect(PromptTarget.foreignProgram(kind: "Claude", program: "claude") == nil)
        #expect(PromptTarget.foreignProgram(kind: "omp", program: nil) == nil, "unknown: not refused")
        #expect(PromptTarget.foreignProgram(kind: nil, program: "tmux") == nil, "no agent reporting")
    }
}
