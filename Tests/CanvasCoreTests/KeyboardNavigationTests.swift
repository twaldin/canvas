import CoreGraphics
import Foundation
import Testing
import CanvasCore

/// Keyboard zoom steps, ⌥⌘-arrow neighbors, Go to's file matching, and the tray's prompt target.
struct KeyboardNavigationTests {
    @Test func keyboardZoomStepsThroughBrowserLevelsWithinTheLimits() {
        let limits: ClosedRange<CGFloat> = 0.1...1
        var zoom: CGFloat = 1
        var outs: [CGFloat] = []
        while true {
            let next = Layout.zoomStep(from: zoom, in: false, limits: limits)
            if next == zoom { break }
            outs.append(next)
            zoom = next
        }
        #expect(outs == [0.9, 0.75, 0.67, 0.5, 0.33, 0.25, 0.15, 0.1], "finer than halving, ending at the minimum")
        #expect(Layout.zoomStep(from: 0.1, in: true, limits: limits) == 0.15)
        #expect(Layout.zoomStep(from: 0.42, in: true, limits: limits) == 0.5, "an arbitrary zoom (a fit) steps to the next level up")
        #expect(Layout.zoomStep(from: 0.42, in: false, limits: limits) == 0.33)
        #expect(Layout.zoomStep(from: 1 / 3, in: false, limits: limits) == 0.25, "a hair off a level counts as on it")
        #expect(Layout.zoomStep(from: 0.95, in: true, limits: limits) == 1, "never past the maximum")
        #expect(Layout.zoomStep(from: 1, in: true, limits: limits) == 1)
        #expect(Layout.zoomStep(from: 0.12, in: false, limits: limits) == 0.1)
    }

    @Test func arrowNeighborPrefersTheSameRowThenTheNearest() {
        let from = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frames = [
            CGRect(x: 600, y: 700, width: 400, height: 300),   // 0: down-right, nearer by center
            CGRect(x: 1200, y: 50, width: 400, height: 300),   // 1: same row, farther
            CGRect(x: -900, y: 0, width: 400, height: 300),    // 2: left
            CGRect(x: 100, y: -800, width: 300, height: 300),  // 3: above
            CGRect(x: 0, y: 500, width: 400, height: 300),     // 4: below
        ]
        #expect(Layout.neighbor(of: from, among: frames, toward: .right) == 1, "a tile in the same row beats a nearer diagonal one")
        #expect(Layout.neighbor(of: from, among: frames, toward: .left) == 2)
        #expect(Layout.neighbor(of: from, among: frames, toward: .up) == 3)
        #expect(Layout.neighbor(of: from, among: frames, toward: .down) == 4)
        #expect(Layout.neighbor(of: frames[2], among: [from], toward: .left) == nil, "nothing that way")
        // Overlapping tiles still count when they lie past the near edge.
        let overlapping = CGRect(x: 300, y: 100, width: 400, height: 300)
        #expect(Layout.neighbor(of: from, among: [overlapping], toward: .right) == 0)
        #expect(Layout.neighbor(of: from, among: [from], toward: .right) == nil, "not itself")
    }

    /// Study geometry: ⌥⌘↓ from an omp terminal went to a code tile off to the right (just past
    /// the terminal's right edge, starting above its bottom) instead of the review tile below it.
    @Test func arrowNeighborPrefersTilesInLineOverNearerOnesBeside() {
        let terminal = CGRect(x: 0, y: 0, width: 1000, height: 620)
        let beside = CGRect(x: 1020, y: 470, width: 640, height: 446)
        let below = CGRect(x: -10, y: 690, width: 740, height: 600)
        #expect(Layout.neighbor(of: terminal, among: [beside, below], toward: .down) == 1, "the tile sharing the terminal's column")
        // A sliver of shared span is not in line: 10 pt of a 640 pt tile.
        let sliver = CGRect(x: 990, y: 470, width: 640, height: 446)
        #expect(Layout.neighbor(of: terminal, among: [sliver, below], toward: .down) == 1)
        // Far below but in line still beats near and off to the side.
        let farBelow = CGRect(x: 200, y: 3000, width: 400, height: 300)
        #expect(Layout.neighbor(of: terminal, among: [beside, farBelow], toward: .down) == 1)
        // With nothing in line, the diagonal one is still reachable.
        #expect(Layout.neighbor(of: terminal, among: [beside], toward: .down) == 0)
        // Across the other axis the same way: → picks the tile sharing the row.
        let right = CGRect(x: 1400, y: 100, width: 400, height: 400)
        let rightLow = CGRect(x: 1030, y: 600, width: 400, height: 400)
        #expect(Layout.neighbor(of: terminal, among: [rightLow, right], toward: .right) == 1)
    }

    @Test func fileSearchRanksFileNamesOverScatteredPathMatches() {
        let index = FileIndex(paths: [
            "docs/maintenance.md",
            "src/manager/index.ts",
            "trusted/cli/src/main.ts",
            "src/main.tsx",
            "packages/domain/src/main_test.ts",
            "README.md",
        ])
        let results = index.search("main.ts", limit: 10)
        #expect(results.first == "src/main.tsx" || results.first == "trusted/cli/src/main.ts")
        #expect(Array(results.prefix(2)).sorted() == ["src/main.tsx", "trusted/cli/src/main.ts"], "the file name itself first")
        #expect(!results.contains("README.md"), "not a subsequence")
        #expect(index.search("main.ts", limit: 1).count == 1, "capped")
        #expect(index.search("", limit: 10).isEmpty, "an empty query lists no files")
        // A subsequence across directories still matches: s·c·l·m → trusted/cli/src/main.ts's words.
        #expect(index.search("clisrcmain", limit: 10) == ["trusted/cli/src/main.ts"])
        #expect(index.search("MAIN", limit: 10).contains("src/main.tsx"), "case-insensitive")
        #expect(index.search("main ts", limit: 3).first.map { $0.hasSuffix("main.ts") || $0.hasSuffix("main.tsx") } == true, "spaces ignored")
        // Word starts beat letters buried inside words.
        let words = FileIndex(paths: ["abc/xyzfoobar.swift", "abc/foo_bar.swift"])
        #expect(words.search("fb", limit: 2).first == "abc/foo_bar.swift")
    }

    @Test func goToQueriesTakeALineOrASymbol() {
        func parse(_ query: String) -> GoToQuery { GoToQuery.parse(query) }
        #expect(parse("core.py:1428") == GoToQuery(text: "core.py", lines: LineRange(start: 1428, end: 1428)))
        #expect(parse(" src/click/core.py:10-20 ") == GoToQuery(text: "src/click/core.py", lines: LineRange(start: 10, end: 20)))
        #expect(parse("core.py:12:7") == GoToQuery(text: "core.py", lines: LineRange(start: 12, end: 12)), "a column is ignored")
        #expect(parse("core.py#L10-L20") == GoToQuery(text: "core.py", lines: LineRange(start: 10, end: 20)))
        #expect(parse("core.py#L7") == GoToQuery(text: "core.py", lines: LineRange(start: 7, end: 7)))
        #expect(parse("core.py:30-10") == GoToQuery(text: "core.py", lines: LineRange(start: 30, end: 30)), "a reversed range is its start")
        #expect(parse("core.py:") == GoToQuery(text: "core.py"), "half-typed: the file alone, still listed")
        #expect(parse("core.py#L") == GoToQuery(text: "core.py"))
        #expect(parse("core.py") == GoToQuery(text: "core.py"))
        #expect(parse(":42") == GoToQuery(text: ":42"), "a line needs a file")
        #expect(parse("@resolve_command") == GoToQuery(text: "resolve_command", symbol: true))
        #expect(parse("@ Group ") == GoToQuery(text: "Group", symbol: true))
        #expect(parse("tstopts") == GoToQuery(text: "tstopts"))
    }

    private func terminal(_ id: ObjectID, agent: String? = nil, running: Bool = false, name: String? = nil) -> CanvasObject {
        var props: [String: JSONValue] = ["cwd": .string("/")]
        if let agent { props["agent"] = .object(["kind": .string(agent)]) }
        if running { props["lifecycle"] = .object(["state": .string("idle")]) }
        if let name { props["name"] = .string(name) }
        return CanvasObject(id: id, type: .terminal, frame: Frame(x: 0, y: 0, w: 10, h: 10), z: 0, parent: nil, createdBy: .user, createdAt: Date(), props: .object(props))
    }

    @Test func promptTargetIsTheLastFocusedAgentThenTheLastFocusedThenTheOnlyTerminal() {
        let omp = terminal("omp", agent: "omp", running: true)
        let nvim = terminal("nvim")
        let shell = terminal("shell")
        let objects = [omp.id: omp, nvim.id: nvim, shell.id: shell]
        #expect(PromptTarget.choose(focusOrder: ["omp", "nvim"], objects: objects) == "omp", "an editor opened later doesn't take the target")
        #expect(PromptTarget.choose(focusOrder: ["nvim", "shell"], objects: objects) == "shell", "no agent focused: the last focused terminal")
        #expect(PromptTarget.choose(focusOrder: [], objects: [nvim.id: nvim]) == "nvim", "a lone terminal needs no focus")
        #expect(PromptTarget.choose(focusOrder: [], objects: objects) == nil, "several, none focused")
        #expect(PromptTarget.choose(focusOrder: ["gone", "shell"], objects: objects) == "shell", "closed terminals are skipped")
        // Two agents: the one focused last.
        let claude = terminal("claude", agent: "claude", running: true)
        let both = objects.merging([claude.id: claude]) { $1 }
        #expect(PromptTarget.choose(focusOrder: ["claude", "omp", "shell"], objects: both) == "omp")
        // An agent that exited (lifecycle cleared, kind remembered) is a plain terminal again.
        let exited = terminal("omp", agent: "omp", running: false)
        #expect(PromptTarget.choose(focusOrder: ["omp", "nvim"], objects: [exited.id: exited, nvim.id: nvim]) == "nvim")
    }

    @Test func trayNamesTheTargetByNameThenTitle() {
        #expect(PromptTarget.label(terminal("a", name: "fees"), shownTitle: "✳ Claude Code") == "fees")
        #expect(PromptTarget.label(terminal("a"), shownTitle: "✳ Claude Code") == "✳ Claude Code")
        #expect(PromptTarget.label(terminal("a"), shownTitle: " ") == "Terminal")
    }

    @Test func editHereUsesTheUsersEditorWithALineWhereItTakesOne() {
        #expect(EditorCommand.argv(editor: "nvim", fallback: "vi", line: 42, path: "a.swift") == ["nvim", "+42", "--", "a.swift"])
        #expect(EditorCommand.argv(editor: "/opt/homebrew/bin/emacsclient -t", fallback: "vi", line: 7, path: "a.swift") == ["/opt/homebrew/bin/emacsclient", "-t", "+7", "a.swift"])
        #expect(EditorCommand.argv(editor: "code -w", fallback: "vi", line: 7, path: "a.swift") == ["code", "-w", "a.swift"], "no +line for editors not known to take it")
        #expect(EditorCommand.argv(editor: nil, fallback: "vi", line: 3, path: "a.swift") == ["vi", "+3", "--", "a.swift"])
        #expect(EditorCommand.argv(editor: "  ", fallback: "nvim", line: 3, path: "a.swift").first == "nvim")
    }
}
