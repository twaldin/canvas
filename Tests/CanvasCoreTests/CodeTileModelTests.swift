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
}

@MainActor
struct CodeBoardTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-tests-\(UUID().uuidString)")

    @Test func followKeepsRecentLocationsNewestFirstWithoutRepeats() throws {
        let board = Board(id: "brd_test", root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a.ts", "b.ts", "c.ts"] { FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data("x\n".utf8)) }
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

    /// omp made three edits within 50 ms, then kept reading: every edit stays in the history,
    /// marked, while older reads make room.
    @Test func followHistoryKeepsEveryEditOfABurstMarked() throws {
        let board = Board(id: "brd_test", root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["core.py", "test_options.py", "CHANGES.md", "parser.py"] { FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data("x\n".utf8)) }
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/"), "command": .array([])]))
        func report(_ path: String, _ line: Int?, _ action: String) throws {
            try board.follow(tile: terminal.id, path: path, range: line.map { LineRange(start: $0, end: $0) }, action: action)
        }
        for line in 1...4 { try report("parser.py", line * 10, "read") }
        try report("core.py", 2535, "edit")
        try report("test_options.py", 83, "edit")
        try report("CHANGES.md", nil, "write")
        for line in 1...10 { try report("parser.py", 100 + line, "read") }
        try report("core.py", 2535, "read")
        let history = try #require(board.followTiles(of: terminal.id).first?.props["history"]?.array)
        #expect(history.count == Board.followHistoryLimit)
        let edits = history.filter { Board.isEdit($0["action"]?.string) }.compactMap { $0["path"]?.string }
        #expect(edits == ["core.py", "CHANGES.md", "test_options.py"], "every edit of the burst, newest first, after ten more reads")
        #expect(history.first?["path"]?.string == "core.py" && history.first?["action"]?.string == "edit",
                "re-reading an edited location keeps it an edit, at the front")
        #expect(history.filter { $0["path"]?.string == "parser.py" }.compactMap { $0["range"]?["start"]?.int } == [110, 109, 108, 107, 106],
                "the newest reads fill the rest")
    }

    @Test func stagedCodeMentionsResolveFromTheirOwnCommitNotTheTile() async throws {
        let repo = try await TempRepo()
        try await repo.write("lib.rs", "fn old()\nfn gone()\n")
        try await repo.write("other.rs", "fn unrelated()\n")
        let base = try await repo.commit("base")
        try await repo.write("lib.rs", "fn new()\n")
        let board = Board(id: "brd_test", root: repo.root)
        let tile = board.create(type: .code, props: .object(["path": .string("lib.rs"), "diffBase": .string("merge-base")]))
        try board.stage(.code(object: tile.id, path: "lib.rs", lines: LineRange(start: 2, end: 2), side: "old", symbol: nil, commit: base))
        try board.stage(.code(object: tile.id, path: "lib.rs", lines: LineRange(start: 1, end: 1), side: "new", symbol: nil, commit: base))
        try board.stage(.code(object: tile.id, path: "lib.rs", lines: LineRange(start: 1, end: 1), side: nil, symbol: nil, commit: base))
        // The reusable tile moves on to another file before the prompt is sent.
        try board.update(tile.id, props: .object(["path": .string("other.rs")]))

        let context = await board.drain().context
        let short = base.prefix(7)
        #expect(context.contains("[1] code lib.rs:2-2 · tile \(tile.id) · diff vs merge-base \(short), old side"))
        #expect(context.contains("  > 2    fn gone()"), "old-side lines come from the mention's commit")
        #expect(context.contains("[2] code lib.rs:1-1 · tile \(tile.id) · diff vs merge-base \(short) (edited)"))
        #expect(context.contains("  > 1    fn new()"), "new-side lines come from the working tree")
        #expect(context.contains("[3] code lib.rs:1-1 · tile \(tile.id) · at \(short)"))
        #expect(context.contains("  > 1    fn old()"), "a pinned excerpt reads the commit")
        #expect(!context.contains("unrelated"))

        let source = board.create(type: .code, props: .object(["path": .string("lib.rs")]))
        try board.stage(.code(object: source.id, path: "lib.rs", lines: LineRange(start: 1, end: 1)))
        #expect(!(await board.drain().context.contains("diff vs")), "working-tree mentions name no base")
    }
}
