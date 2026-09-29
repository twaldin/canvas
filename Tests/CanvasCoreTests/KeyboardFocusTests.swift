import CoreGraphics
import Foundation
import Testing
import CanvasCore

/// Where the keyboard goes when the user turns to another tile, which code tile Code ▸ commands
/// act on, what a changes tile's keys start on and say, and what the close sheet names.
struct KeyboardFocusTests {
    let code = KeyboardFocus.Holder("code", isTerminal: false)
    let shell = KeyboardFocus.Holder("shell", isTerminal: true)

    @Test func selectingAnotherTileTakesTheKeyboardFromATileButNotFromATerminal() {
        #expect(KeyboardFocus.afterSelectionChange(["other"], holder: code) == .canvas, "s in a changes tile nobody is looking at")
        #expect(KeyboardFocus.afterSelectionChange([], holder: code) == .canvas)
        #expect(KeyboardFocus.afterSelectionChange(["code", "other"], holder: code) == .canvas, "the ring and the keys never part")
        #expect(KeyboardFocus.afterSelectionChange(["code"], holder: code) == .stay, "a click inside the tile that has the keyboard")
        #expect(KeyboardFocus.afterSelectionChange(["other"], holder: shell) == .stay, "the mouse selects while the user talks to the agent")
        #expect(KeyboardFocus.afterSelectionChange(["other"], holder: nil) == .stay)
    }

    @Test func aTitleBarPressHandsTheKeyboardToTheTileOrTheCanvas() {
        #expect(KeyboardFocus.afterTitleBarPress(on: "follow", isTerminal: false, holder: code) == .canvas)
        #expect(KeyboardFocus.afterTitleBarPress(on: "follow", isTerminal: false, holder: shell) == .canvas, "a terminal loses it too")
        #expect(KeyboardFocus.afterTitleBarPress(on: "follow", isTerminal: false, holder: nil) == .canvas)
        #expect(KeyboardFocus.afterTitleBarPress(on: "agent", isTerminal: true, holder: code) == .terminal("agent"))
        #expect(KeyboardFocus.afterTitleBarPress(on: "code", isTerminal: false, holder: code) == .stay, "dragging the tile you're in keeps you in it")
        #expect(KeyboardFocus.afterTitleBarPress(on: "shell", isTerminal: true, holder: shell) == .stay)
    }

    @Test func codeCommandsActOnTheFocusedThenSelectedThenLastClickedCodeTile() {
        let codes: Set<ObjectID> = ["a", "b", "c"]
        func target(_ focused: ObjectID?, _ selection: Set<ObjectID>, _ clicked: ObjectID?) -> ObjectID? {
            KeyboardFocus.codeTarget(focused: focused, selection: selection, lastClicked: clicked) { codes.contains($0) }
        }
        #expect(target("a", ["b"], "c") == "a")
        #expect(target("shell", ["b"], "c") == "b", "a terminal keeps the keyboard after ⌘-clicking a reference; the preview is selected")
        #expect(target("shell", ["b", "c"], "c") == "c")
        #expect(target(nil, [], "c") == "c", "a click that left nothing selected still names the tile")
        #expect(target("shell", ["note"], "shell") == nil, "nothing to act on: the command says so")
    }

    @Test func codeCommandsFromTheKeyboardActOnTheFirstNameAtOrBelowTheTilesAnchorLine() {
        // A follow tile aimed at line 17 of AgentReportSpool.swift (a closing brace), as filmed:
        // ⌃⌘R did nothing and said nothing.
        let file = [
            14: "    public var method: String",
            15: "    public var params: JSONValue",
            16: "    public var file: URL",
            17: "}",
            18: "",
            19: "/// The spooled reports of `tiles`, oldest first.",
            20: "@MainActor",
            21: "public static func read(from directory: URL, tiles: [ObjectID]) -> [Entry] {",
        ]
        let line: (Int) -> String = { file[$0] ?? "" }
        #expect(CodeSubject.first(from: 15, through: 21, line: line) == CodeSubject.Position(line: 15, character: 15), "`params`, past the keywords")
        #expect(CodeSubject.first(from: 17, through: 21, line: line) == CodeSubject.Position(line: 21, character: 19),
                "`read`: past the brace, the blank line, the doc comment and the attribute")
        #expect(CodeSubject.first(from: 17, through: 20, line: line) == nil, "nothing named in view: the command says so")
    }

    @Test func theHeaderDropsItsHintBeforeItCutsTheSummary() {
        let width: (String) -> CGFloat = { CGFloat($0.count) * 6 }
        let full = ChangesMetrics.keysHints[0], compact = ChangesMetrics.keysHints[1], shortest = ChangesMetrics.keysHints.last!
        let summary: CGFloat = 260
        func hint(_ available: CGFloat) -> String? { ChangesMetrics.hint(ChangesMetrics.keysHints, available: available, summary: summary, width: width) }
        #expect(hint(2000) == full)
        #expect(hint(summary + ChangesMetrics.hintGap + width(full) - 1) == compact, "a narrower tile still says which keys work")
        #expect(hint(summary + ChangesMetrics.hintGap + width(shortest)) == shortest)
        #expect(hint(summary + ChangesMetrics.hintGap + width(shortest) - 1) == nil, "the whole summary stays: the hint goes first")
    }

    @Test func takingAChangesTilesKeyboardStartsOnTheFirstHunkInView() async throws {
        let repo = try await TempRepo()
        try await repo.write("a.txt", numbered(1...60))
        try await repo.write("b.txt", numbered(1...10))
        try await repo.commit("base")
        try await repo.write("a.txt", numbered(1...60).replacingOccurrences(of: "line 5\n", with: "line 5 x\n").replacingOccurrences(of: "line 50\n", with: "line 50 x\n"))
        try await repo.write("b.txt", numbered(1...10).replacingOccurrences(of: "line 2\n", with: "line 2 x\n"))
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object([:])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        let rows = ChangeRows(set, collapsed: [])
        let second = try #require(rows.index(ofHunk: 0, 1))
        let top = rows.tops[second]
        let picked = try #require(rows.firstHunk(inView: top, top + 200))
        #expect(picked.file == 0 && picked.hunk == 1 && picked.inView, "what the user is looking at, not the top of the list")
        let listTop = try #require(rows.firstHunk(inView: 0, 1))
        #expect(listTop.file == 0 && listTop.hunk == 0 && !listTop.inView, "only the file list in view: the first hunk, to be scrolled to")
        let folded = ChangeRows(set, collapsed: [set.files[0].boardPath])
        #expect(folded.firstHunk(inView: 0, 1).map { [$0.file, $0.hunk] } == [1, 0], "folded files' hunks aren't picked")
        #expect(ChangeRows(set, collapsed: Set(set.files.map(\.boardPath))).firstHunk(inView: 0, 10_000) == nil)
    }

    @Test func theCloseSheetNamesTheProgramAndWhatItStarted() {
        let omp = SessionProcesses(shell: 10, foreground: 11, processes: [
            .init(pid: 11, parent: 10, argv: ["bun", "/opt/omp/bin/omp"]),
            .init(pid: 12, parent: 11, argv: ["/bin/bash", "-c", "pnpm exec next dev"]),
            .init(pid: 13, parent: 12, argv: ["node", "/opt/homebrew/bin/pnpm", "exec", "next", "dev"]),
            .init(pid: 14, parent: 13, argv: ["node", "/repo/node_modules/.bin/next", "dev"]),
        ])
        #expect(omp.program == "omp")
        #expect(omp.background == ["pnpm exec next"], "a server's wrapper shell and its own workers count as one")
        #expect(SessionProcesses.closingText([omp]) == "Closing it ends omp and 1 background process (pnpm exec next).")

        let prompt = SessionProcesses(shell: 20, foreground: nil, processes: [])
        #expect(SessionProcesses.closingText([prompt]) == "Closing it ends its shell; nothing else is running in it.")
        let jobs = SessionProcesses(shell: 30, foreground: nil, processes: [
            .init(pid: 31, parent: 30, argv: ["vite"]), .init(pid: 32, parent: 30, argv: ["cargo", "watch"]),
        ])
        #expect(SessionProcesses.closingText([jobs]) == "Closing it ends its shell and 2 background processes (vite, cargo watch).")
        #expect(SessionProcesses.closingText([nil]) == "Closing it ends anything running in it.", "the shell not found yet")
        #expect(SessionProcesses.closingText([omp, prompt, nil]) == "Closing them ends omp, 1 idle shell, 1 background process (pnpm exec next) and anything running in the other.")
        // Closing a board's tab ends nothing: its sheet says what keeps running (footprint F4).
        #expect(SessionProcesses.keepRunningText([omp, prompt, nil]) == "omp, 1 idle shell, 1 background process (pnpm exec next) and 1 terminal keep running")
        #expect(SessionProcesses.keepRunningText([SessionProcesses(shell: 1, foreground: 2, processes: [.init(pid: 2, parent: 1, argv: ["codex"])])]) == "codex keeps running")
    }

    @Test func sessionProcessesAreTheShellsDescendants() {
        let table: [(pid: Int32, parent: Int32)] = [(1, 0), (10, 1), (11, 10), (12, 11), (20, 1), (21, 20), (13, 12)]
        #expect(SessionProcesses.descendants(of: 10, in: table).map(\.pid).sorted() == [11, 12, 13])
        #expect(SessionProcesses.descendants(of: 13, in: table).isEmpty)
    }
}
