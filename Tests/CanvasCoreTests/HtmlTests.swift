import Foundation
import Testing
import CanvasCore

private func message(_ json: String) throws -> HtmlMessage {
    try HtmlMessage.parse(Data(json.utf8))
}

private func rejection(_ json: String) -> HtmlError? {
    do {
        _ = try message(json)
        return nil
    } catch {
        return error as? HtmlError
    }
}

struct HtmlMessageTests {
    @Test func acceptsEachMessageType() throws {
        #expect(try message(#"{"type":"code.excerpt","path":"src/a.swift","lines":"10-40","symbol":"Board.update"}"#)
            == .excerpt(path: "src/a.swift", lines: LineRange(start: 10, end: 40), symbol: "Board.update"))
        #expect(try message(#"{"type":"code.open","path":"src/a.swift","lines":"12"}"#)
            == .openCode(path: "src/a.swift", lines: LineRange(start: 12, end: 12), symbol: nil))
        #expect(try message(#"{"type":"state.set","key":"plan","value":{"choice":"b"}}"#)
            == .setState(key: "plan", value: .object(["choice": .string("b")])))
        #expect(try message(#"{"type":"state.set","key":"plan","value":null}"#) == .setState(key: "plan", value: .null))
        #expect(try message(#"{"type":"state.get"}"#) == .getState(key: nil))
        #expect(try message(#"{"type":"view.rendered","scrollY":120}"#) == .rendered(scrollY: 120))
    }

    @Test func rejectsUnknownTypesAndFields() {
        #expect(rejection(#"{"type":"fs.read","path":"x"}"#) == .unknownType("fs.read"))
        #expect(rejection(#"{"type":"code.excerpt","path":"x","url":"https://evil"}"#) == .unexpectedField("url"))
        #expect(rejection(#"{"path":"x"}"#) == .malformed("missing type"))
        #expect(rejection(#"["code.excerpt"]"#) == .malformed("message must be an object"))
        #expect(rejection("not json") == .malformed("not JSON"))
    }

    @Test func rejectsMalformedFields() {
        for lines in ["40-10", "0", "1-2-3", "abc", "-4", "1-", "１２"] {
            #expect(rejection(#"{"type":"code.excerpt","path":"a","lines":"\#(lines)"}"#) != nil, "lines \(lines)")
        }
        #expect(rejection(#"{"type":"code.excerpt","path":""}"#) != nil)
        #expect(rejection(#"{"type":"code.excerpt","path":"a","symbol":"x;rm -rf"}"#) != nil)
        #expect(rejection(#"{"type":"state.set","key":"../x","value":1}"#) != nil)
        #expect(rejection(#"{"type":"state.set","key":"k"}"#) == .invalidField("value", "required"))
        #expect(rejection(#"{"type":"view.rendered","scrollY":-1}"#) != nil)
    }

    @Test func rejectsOversizeMessagesAndValues() {
        let big = String(repeating: "x", count: HtmlMessage.maxMessageBytes)
        guard case .tooLarge(_, HtmlMessage.maxMessageBytes) = rejection(#"{"type":"code.excerpt","path":"\#(big)"}"#) else {
            Issue.record("a message over the byte cap must be rejected before decoding")
            return
        }
        let value = String(repeating: "y", count: HtmlMessage.maxStateValueBytes)
        guard case .tooLarge(_, HtmlMessage.maxStateValueBytes) = rejection(#"{"type":"state.set","key":"k","value":"\#(value)"}"#) else {
            Issue.record("a state value over the cap must be rejected")
            return
        }
    }
}

struct HtmlPathTests {
    let root: URL
    let outside: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-html-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "code".write(to: root.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    }

    @Test func boardFilesStayInsideTheRoot() throws {
        #expect(try HtmlKit.boardFile("./src//a.swift", root: root).relative == "src/a.swift")
        for path in ["../outside/secret.txt", "src/../../outside/secret.txt", "/etc/passwd", "~/.ssh/id_rsa", "escape/secret.txt", ".", ""] {
            #expect(throws: HtmlError.self, "\(path)") { try HtmlKit.boardFile(path, root: root) }
        }
    }

    @Test func kitServesOnlyRegularFilesInsideTheKit() throws {
        let kit = root.appendingPathComponent("kit")
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("vendor"), withIntermediateDirectories: true)
        try "js".write(to: kit.appendingPathComponent("vendor/m.js"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: kit.appendingPathComponent("out"), withDestinationURL: outside)

        #expect(HtmlKit.kitFile(requestPath: "/kit/vendor/m.js", kitRoot: kit)?.lastPathComponent == "m.js")
        for path in ["/kit/../src/a.swift", "/kit/vendor/../../src/a.swift", "/kit/out/secret.txt", "/kit/vendor", "/kit/vendor//m.js", "/other/m.js", "/kit/missing.js"] {
            #expect(HtmlKit.kitFile(requestPath: path, kitRoot: kit) == nil, "\(path)")
        }
        // URL decodes percent escapes before the path reaches the check.
        let encoded = URL(string: "canvas-kit://html/kit/%2e%2e/src/a.swift")!
        #expect(HtmlKit.kitFile(requestPath: encoded.path, kitRoot: kit) == nil)
    }

    @Test func networkAllowlistAcceptsOnlyHosts() {
        #expect(HtmlKit.allowedHost("LOCALHOST:8123") == "localhost:8123")
        #expect(HtmlKit.allowedHost("*.github.io") == "*.github.io")
        #expect(HtmlKit.allowedHost("api.example.com") == "api.example.com")
        for entry in ["https://example.com", "example.com/path", "exa mple.com", "a|b.com", "*", "*.", "host:99999", "-bad.com", "a..b"] {
            #expect(HtmlKit.allowedHost(entry) == nil, "\(entry)")
        }
    }
}

struct SourceExcerptTests {
    static let swift = """
    import Foundation

    /// Holds things.
    @MainActor
    final class Store {
        var items: [String] = []

        /// Adds one.
        func add(_ item: String) {
            if item.isEmpty { return }
            items.append("{\\(item)}")
        }
    }

    let limit = 5
    """

    @Test func linesResolveExactly() {
        let excerpt = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: LineRange(start: 5, end: 6), symbol: nil)
        #expect(excerpt.lines == ["final class Store {", "    var items: [String] = []"])
        #expect((excerpt.start, excerpt.end, excerpt.stale) == (5, 6, false))
        #expect(excerpt.language == "swift")
    }

    @Test func symbolsResolveToTheirDeclarationWithDocs() {
        let store = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: nil, symbol: "Store")
        #expect((store.start, store.end, store.stale) == (3, 13, false), "doc comment and attribute through the closing brace")

        let add = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: LineRange(start: 1, end: 2), symbol: "Store.add")
        #expect((add.start, add.end) == (8, 12), "the symbol wins over drifted lines; braces inside strings don't count")
        #expect(add.lines.last == "    }")

        let constant = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: nil, symbol: "limit")
        #expect((constant.start, constant.end) == (15, 15))
    }

    @Test func pythonBlocksEndAtDedent() {
        let python = "import os\n\ndef load(path,\n         mode):\n    # read it\n    with open(path) as f:\n        return f.read()\n\nx = load('a', 'r')\n"
        let excerpt = SourceExcerpt.resolve(text: python, path: "a.py", lines: nil, symbol: "load")
        #expect((excerpt.start, excerpt.end) == (3, 7))
    }

    @Test func lostAnchorsAreStaleWithAReason() {
        let missing = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: nil, symbol: "remove")
        #expect(missing.stale && missing.lines.isEmpty)
        #expect(missing.reason?.contains("remove") == true)

        let fallback = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: LineRange(start: 9, end: 9), symbol: "remove")
        #expect(fallback.stale && fallback.lines == ["    func add(_ item: String) {"], "a lost symbol still shows the recorded lines, marked stale")

        let past = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: LineRange(start: 40, end: 50), symbol: nil)
        #expect(past.stale && past.lines.isEmpty)

        let clamped = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: LineRange(start: 14, end: 50), symbol: nil)
        #expect(clamped.stale && (clamped.start, clamped.end) == (14, 15))

        let file = SourceExcerpt.load(url: URL(fileURLWithPath: "/nonexistent/x.swift"), path: "x.swift", lines: LineRange(start: 1, end: 2), symbol: nil)
        #expect(file.stale && file.reason == "x.swift not found")
    }

    @Test func longRangesAreTruncated() {
        let text = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = SourceExcerpt.resolve(text: text, path: "big.txt", lines: LineRange(start: 100, end: 900), symbol: nil)
        #expect(excerpt.truncated && !excerpt.stale)
        #expect(excerpt.lines.count == SourceExcerpt.maxLines && excerpt.lines.first == "line 100")
    }
}

@MainActor
struct HtmlChannelTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-html-\(UUID().uuidString)")
    let board: Board
    let html: CanvasObject

    init() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try SourceExcerptTests.swift.write(to: root.appendingPathComponent("src/Store.swift"), atomically: true, encoding: .utf8)
        board = Board(id: "brd_test", root: root)
        html = board.create(type: .html, props: .object(["html": .string("<p>hi</p>")]), frame: Frame(x: 0, y: 0, w: 640, h: 480))
    }

    @Test func excerptsReadBoardFilesButNotOutsideIt() async throws {
        let excerpt = try await HtmlChannel.handle(.excerpt(path: "src/Store.swift", lines: nil, symbol: "Store.add"), tile: html.id, board: board)
        #expect(excerpt["start"] == .number(8) && excerpt["stale"] == .bool(false))

        await #expect(throws: HtmlError.outsideRoot("../etc/passwd")) {
            try await HtmlChannel.handle(.excerpt(path: "../etc/passwd", lines: nil, symbol: nil), tile: html.id, board: board)
        }
    }

    @Test func openCodeCreatesBesideThenReaimsTheSameTile() async throws {
        let first = try await HtmlChannel.handle(.openCode(path: "src/Store.swift", lines: nil, symbol: "Store.add"), tile: html.id, board: board)
        #expect(first["created"] == .bool(true))
        let id = try #require(first["tile"]?.string)
        let code = try board.object(id)
        #expect(code.frame.x >= html.frame.maxX, "opens to the right of the HTML tile")
        #expect(code.props["range"] == .object(["start": .number(8), "end": .number(12)]))
        #expect(code.createdBy == .user)

        let second = try await HtmlChannel.handle(.openCode(path: "./src/Store.swift", lines: LineRange(start: 15, end: 15), symbol: nil), tile: html.id, board: board)
        #expect(second == .object(["tile": .string(id), "created": .bool(false)]))
        #expect(try board.object(id).props["range"] == .object(["start": .number(15), "end": .number(15)]))
        #expect(try board.object(id).props["symbol"] == nil)

        await #expect(throws: HtmlError.notFound("src/Missing.swift")) {
            try await HtmlChannel.handle(.openCode(path: "src/Missing.swift", lines: nil, symbol: nil), tile: html.id, board: board)
        }
    }

    @Test func followTilesAreNeverReaimed() async throws {
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]))
        let follow = try board.follow(tile: terminal.id, path: "src/Store.swift", range: nil, action: "read")
        let opened = try await HtmlChannel.handle(.openCode(path: "src/Store.swift", lines: LineRange(start: 1, end: 1), symbol: nil), tile: html.id, board: board)
        #expect(opened["created"] == .bool(true) && opened["tile"]?.string != follow.id)
    }

    @Test func stateKeysPersistAndClear() async throws {
        _ = try await HtmlChannel.handle(.setState(key: "plan", value: .string("b")), tile: html.id, board: board)
        _ = try await HtmlChannel.handle(.setState(key: "notes", value: .array([.number(1)])), tile: html.id, board: board)
        #expect(try board.object(html.id).props["state"] == .object(["plan": .string("b"), "notes": .array([.number(1)])]))
        #expect(try board.object(html.id).props["html"] == .string("<p>hi</p>"))

        _ = try await HtmlChannel.handle(.setState(key: "plan", value: .null), tile: html.id, board: board)
        let got = try await HtmlChannel.handle(.getState(key: "plan"), tile: html.id, board: board)
        #expect(got == .object(["value": .null]))

        let chunk = JSONValue.string(String(repeating: "z", count: 15_000))
        await #expect(throws: HtmlError.self, "total state is capped") {
            for index in 0..<20 {
                _ = try await HtmlChannel.handle(.setState(key: "k\(index)", value: chunk), tile: html.id, board: board)
            }
        }
    }
}
