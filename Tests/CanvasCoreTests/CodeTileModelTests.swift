import Foundation
import Testing
@testable import CanvasCore

struct SyntaxTests {
    @Test func everyBundledLanguageHighlightsItsKeywordsAndStrings() throws {
        let samples: [(SyntaxLanguage, String, keyword: String, string: String)] = [
            (.swift, "func greet() { let s = \"hi\" }\n", "func", "\"hi\""),
            (.typescript, "export function f(): string { return \"hi\" }\n", "function", "\"hi\""),
            (.tsx, "const el = <div title=\"hi\" />\nexport function f() {}\n", "function", "\"hi\""),
            (.javascript, "function f() { return 'hi' }\n", "function", "'hi'"),
            (.python, "def f():\n    return \"hi\"\n", "def", "\"hi\""),
            (.bash, "if true; then echo \"hi\"; fi\n", "if", "\"hi\""),
            (.go, "package main\nfunc f() string { return \"hi\" }\n", "func", "\"hi\""),
            (.rust, "fn f() -> &'static str { \"hi\" }\n", "fn", "\"hi\""),
        ]
        for (language, text, keyword, string) in samples {
            let spans = Syntax.analyze(text, language: language).spans
            let source = text as NSString
            func style(of token: String) -> SyntaxStyle? {
                let range = source.range(of: token)
                // The last span covering the token's middle wins, as when applied in order.
                return spans.last { NSLocationInRange(range.location + range.length / 2, $0.range) }?.style
            }
            #expect(style(of: keyword) == .keyword, "\(language) keyword")
            #expect(style(of: string) == .string, "\(language) string")
        }
        let json = Syntax.analyze("{\"key\": 12}\n", language: .json).spans
        #expect(json.contains { $0.style == .number }, "json numbers")
    }

    @Test func enclosingSymbolIsTheInnermostQualifiedDeclaration() {
        let swift = """
        struct Board {
            func follow() {
                let x = 1
            }
        }
        func free() {}
        """
        let analysis = Syntax.analyze(swift, language: .swift)
        #expect(analysis.enclosingSymbol(line: 3) == "Board.follow")
        #expect(analysis.enclosingSymbol(line: 1) == "Board")
        #expect(analysis.enclosingSymbol(line: 6) == "free")

        let ts = "export class Store {\n  load(id: string) {\n    return id\n  }\n}\nconst run = () => {\n  go()\n}\n"
        let script = Syntax.analyze(ts, language: .typescript)
        #expect(script.enclosingSymbol(line: 3) == "Store.load")
        #expect(script.enclosingSymbol(line: 7) == "run")

        let python = Syntax.analyze("class A:\n    def b(self):\n        pass\n\nx = 1\n", language: .python)
        #expect(python.enclosingSymbol(line: 3) == "A.b")
        #expect(python.enclosingSymbol(line: 5) == nil)
    }

    @Test func languageFollowsTheFileName() {
        #expect(SyntaxLanguage(path: "src/app.tsx") == .tsx)
        #expect(SyntaxLanguage(path: "Sources/Board.swift") == .swift)
        #expect(SyntaxLanguage(path: "home/.zshrc") == .bash)
        #expect(SyntaxLanguage(path: "README.md") == nil)
    }

    @Test func deletedRowsTakeOldSideHighlightsAndOthersTheNewSide() throws {
        let old = SideText("let a = 1\nlet b = \"x\"\n")
        let new = SideText("let a = 1\nvar b = 2\n")
        let diff = FileDiff(state: .modified, base: "abc", baseLabel: nil, old: old, new: new, hunks: [DiffHunk(mappings: [LineRangeMapping(original: 2..<3, modified: 2..<3)])])
        let display = DiffDisplay(diff, mode: .diff)
        let placed = display.place(old: Syntax.analyze(old.text, language: .swift).spans, new: Syntax.analyze(new.text, language: .swift).spans, diff: diff)
        let text = display.text as NSString
        func style(of token: String) -> SyntaxStyle? {
            let range = text.range(of: token)
            return placed.last { NSLocationInRange(range.location, $0.range) }?.style
        }
        #expect(style(of: "\"x\"") == .string, "the deleted row keeps its old-side string highlight")
        #expect(style(of: "var") == .keyword)
    }
}

@MainActor
struct CodeBoardTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-tests-\(UUID().uuidString)")

    @Test func followKeepsRecentLocationsNewestFirstWithoutRepeats() throws {
        let board = Board(id: "brd_test", root: root)
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/"), "command": .array([])]))
        try board.follow(tile: terminal.id, path: "a.ts", range: LineRange(start: 1, end: 2), action: "read")
        try board.follow(tile: terminal.id, path: "b.ts", range: nil, action: "edit")
        let follow = try #require(try board.follow(tile: terminal.id, path: "a.ts", range: LineRange(start: 1, end: 2), action: "read"))
        let history = follow.props["history"]?.array ?? []
        #expect(history.map { $0["path"]?.string } == ["a.ts", "b.ts"], "revisiting a location moves it to the front")
        #expect(history[0]["range"]?["start"]?.int == 1)

        for line in 1...20 { try board.follow(tile: terminal.id, path: "c.ts", range: LineRange(start: line, end: line), action: "read") }
        #expect(board.objects[follow.id]?.props["history"]?.array?.count == Board.followHistoryLimit)
    }

    @Test func stagedCodeMentionsResolveFromTheirOwnCommitNotTheTile() async throws {
        let repo = try await TempRepo()
        try await repo.write("lib.rs", "fn old()\nfn gone()\n")
        try await repo.write("other.rs", "fn unrelated()\n")
        let base = try await repo.commit("base")
        try await repo.write("lib.rs", "fn new()\n")
        let board = Board(id: "brd_test", root: repo.root)
        let tile = board.create(type: .code, props: .object(["path": .string("lib.rs"), "mode": .string("diff"), "diffBase": .string("merge-base")]))
        try board.stage(.code(object: tile.id, path: "lib.rs", lines: LineRange(start: 2, end: 2), side: "old", symbol: nil, commit: base))
        try board.stage(.code(object: tile.id, path: "lib.rs", lines: LineRange(start: 1, end: 1), side: "new", symbol: nil, commit: base))
        try board.stage(.code(object: tile.id, path: "lib.rs", lines: LineRange(start: 1, end: 1), side: nil, symbol: nil, commit: base))
        // The reusable tile moves on to another file in source mode before the prompt is sent.
        try board.update(tile.id, props: .object(["path": .string("other.rs"), "mode": .string("source")]))

        let context = await board.drain().context
        let short = base.prefix(7)
        #expect(context.contains("[1] code lib.rs:2-2 · tile \(tile.id) · diff vs merge-base \(short), old side"))
        #expect(context.contains("  > 2    fn gone()"), "old-side lines come from the mention's commit")
        #expect(context.contains("[2] code lib.rs:1-1 · tile \(tile.id) · diff vs merge-base \(short) (edited)"))
        #expect(context.contains("  > 1    fn new()"), "new-side lines come from the working tree")
        #expect(context.contains("[3] code lib.rs:1-1 · tile \(tile.id) · at \(short)"))
        #expect(context.contains("  > 1    fn old()"), "a pinned excerpt reads the commit")
        #expect(!context.contains("unrelated"))

        let source = board.create(type: .code, props: .object(["path": .string("lib.rs"), "mode": .string("source")]))
        try board.stage(.code(object: source.id, path: "lib.rs", lines: LineRange(start: 1, end: 1)))
        #expect(!(await board.drain().context.contains("diff vs")), "working-tree mentions name no base")
    }
}
