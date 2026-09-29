import CoreGraphics
import Foundation
import Testing
@testable import CanvasCore

/// Calls diagrams built through the real `LanguageService` from sourcekit-lsp answers recorded
/// on the package these tests write (Fixtures/call-hierarchy-sourcekit.json), replayed by a
/// stand-in server: epoch a, then epoch b after an edit that moves `replay(on:)` down, deletes
/// `relaunch()` and makes `warm()` stop calling; epoch c deletes `Spool.read` itself.
@MainActor
final class DiagramTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-diagram-\(UUID().uuidString.prefix(8))")
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/call-hierarchy-sourcekit.json")

    static let spool = """
    public enum Spool {
        /// Reads what the spool holds.
        public static func read(from directory: String,
                                limit: Int) -> [String] {
            Array([directory].prefix(limit))
        }
    }

    """

    static let registryA = """
    public struct Registry {
        public init() {}

        public func open(root: String) -> Int {
            replay(on: root)
        }

        func replay(on root: String) -> Int {
            Spool.read(from: root, limit: 1).count
        }
    }

    func relaunch() -> Int {
        Spool.read(from: "/tmp", limit: 1).count + Spool.read(from: "/var", limit: 2).count
    }

    func warm() -> Int {
        Spool.read(from: "/warm", limit: 1).count
    }

    """

    static let registryB = """
    // The registry of open roots.
    // It replays what the spool held
    // when a root opens.
    public struct Registry {
        public init() {}

        public func open(root: String) -> Int {
            replay(on: root)
        }

        func replay(on root: String) -> Int {
            Spool.read(from: root, limit: 1).count
        }
    }

    func warm() -> Int {
        0
    }

    """

    /// Answers each request from the fixture's current epoch (the `.epoch` file in the root);
    /// the capabilities are the fixture's unless the second argument overrides them.
    static let replayServer = #"""
    import json, os, sys, urllib.parse
    fixture = json.load(open(sys.argv[1]))
    capabilities = json.loads(sys.argv[2]) if len(sys.argv) > 2 else fixture["capabilities"]
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    root_uri = root = None

    def read():
        length = 0
        while True:
            line = stdin.readline()
            if not line:
                sys.exit(0)
            line = line.strip()
            if not line:
                break
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":")[1])
        return json.loads(stdin.read(length))

    def relative(uri):
        return urllib.parse.unquote(uri)[len(root_uri) + 1:]

    while True:
        message = read()
        method, params = message.get("method"), message.get("params") or {}
        if "id" not in message:
            if method == "exit":
                sys.exit(0)
            continue
        if method == "initialize":
            root_uri = params["rootUri"].rstrip("/")
            root = urllib.parse.unquote(root_uri[len("file://"):])
            result = {"capabilities": capabilities}
        elif method == "shutdown":
            result = None
        else:
            marker = os.path.join(root, ".epoch")
            answers = fixture["epochs"][open(marker).read().strip() if os.path.exists(marker) else "a"]
            if method == "textDocument/documentSymbol":
                key = "documentSymbol " + relative(params["textDocument"]["uri"])
            elif method == "textDocument/prepareCallHierarchy":
                key = "prepare %s:%d:%d" % (relative(params["textDocument"]["uri"]), params["position"]["line"], params["position"]["character"])
            elif method == "callHierarchy/incomingCalls":
                key = "incoming " + params["item"]["name"]
            elif method == "callHierarchy/outgoingCalls":
                key = "outgoing " + params["item"]["name"]
            else:
                key = None
            result = json.loads(json.dumps(answers.get(key)).replace("file://ROOT", root_uri))
        body = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}).encode()
        stdout.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        stdout.flush()
    """#

    let service: LanguageService

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent(".replay.py")
        try Self.replayServer.write(to: script, atomically: true, encoding: .utf8)
        service = LanguageService(configs: [Self.server(script)])
        try write("Package.swift", "// swift-tools-version: 5.9\n")
        try write("Sources/Lib/Spool.swift", Self.spool)
        try write("Sources/Lib/Registry.swift", Self.registryA)
    }

    deinit {
        let service = service, dir = dir
        Task { await service.stopAll(); try? FileManager.default.removeItem(at: dir) }
    }

    static func server(_ script: URL, capabilities: String? = nil) -> LanguageServerConfig {
        LanguageServerConfig(language: "swift", command: "/usr/bin/python3", arguments: [script.path, fixture.path] + (capabilities.map { [$0] } ?? []),
                             languageIDs: ["swift": "swift"], rootMarkers: ["Package.swift"])
    }

    func write(_ relative: String, _ text: String) throws {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Epoch b: the code as edited (and re-indexed).
    func edit() throws {
        try write("Sources/Lib/Registry.swift", Self.registryB)
        try write(".epoch", "b")
    }

    func build(_ spec: DiagramSpec, previous: DiagramGraph? = nil) async throws -> DiagramGraph {
        try await CallGraphBuilder.build(spec, boardRoot: dir, previous: previous, languages: service)
    }

    static let root = "Sources/Lib/Spool.swift#Spool.read(from:limit:)"
    static let replay = "Sources/Lib/Registry.swift#Registry.replay(on:)"
    static let open = "Sources/Lib/Registry.swift#Registry.open(root:)"
    static let relaunch = "Sources/Lib/Registry.swift#relaunch()"
    static let warm = "Sources/Lib/Registry.swift#warm()"

    static let callers = DiagramSpec(path: "Sources/Lib/Spool.swift", symbol: "Spool.read", direction: .incoming, depth: 1)

    // MARK: The graph

    @Test func callersAreSymbolAnchoredNodesWithTheirCallsAndAClickOpensOneMoreLevel() async throws {
        let graph = try await build(Self.callers)
        #expect(graph.error == nil)
        #expect(graph.root == Self.root)
        let root = try #require(graph.node(Self.root))
        #expect(root.container == "Spool" && root.name == "read(from:limit:)" && root.line == 3 && root.lines == LineRange(start: 3, end: 6))
        // A signature over two lines is shown whole, without its brace.
        #expect(root.excerpt == [DiagramExcerptLine(line: 3, text: "public static func read(from directory: String,"),
                                 DiagramExcerptLine(line: 4, text: "limit: Int) -> [String]")])

        // Each caller once, at the level left of the root, showing the lines making its calls;
        // every one has a next level not yet asked for.
        #expect(graph.nodes.filter { $0.level == -1 }.map(\.id) == [Self.replay, Self.relaunch, Self.warm])
        let replay = try #require(graph.node(Self.replay))
        #expect(replay.qualifiedName == "Registry.replay(on:)" && replay.line == 8 && replay.lines == LineRange(start: 8, end: 10))
        #expect(replay.excerpt == [DiagramExcerptLine(line: 9, text: "Spool.read(from: root, limit: 1).count")])
        #expect(graph.nodes.filter { $0.level == -1 }.allSatisfy { $0.expandable == true })
        // relaunch() calls twice on one line: one edge, one line.
        #expect(graph.edges.first { $0.from == Self.relaunch } == DiagramEdge(from: Self.relaunch, to: Self.root, lines: [14]))
        #expect(graph.edges.allSatisfy { $0.to == Self.root })

        var expanded = Self.callers
        expanded.expanded = [Self.replay]
        let deeper = try await build(expanded, previous: graph)
        #expect(deeper.node(Self.replay)?.expanded == true && deeper.node(Self.replay)?.expandable == nil)
        #expect(deeper.node(Self.open)?.level == -2 && deeper.node(Self.open)?.expandable == true)
        #expect(deeper.edges.contains(DiagramEdge(from: Self.open, to: Self.replay, lines: [5])))
        #expect(deeper.node(Self.relaunch)?.expandable == true)
    }

    // MARK: Freshness

    @Test func aNodeWhoseSymbolIsGoneStaysStaleWhileMovedCodeKeepsItsNode() async throws {
        var spec = Self.callers
        spec.expanded = [Self.replay]
        let before = try await build(spec)
        try edit()
        let after = try await build(spec, previous: before)

        // replay(on:) moved down three lines: the same node, re-resolved.
        #expect(after.node(Self.replay)?.line == 11)
        #expect(after.node(Self.replay)?.isStale == false)
        #expect(after.node(Self.open)?.isStale == false)
        // relaunch() is gone from the file: kept as it was, badged, with its call.
        let relaunch = try #require(after.node(Self.relaunch))
        #expect(relaunch.isStale && relaunch.line == 13 && relaunch.expandable == nil)
        #expect(after.edges.contains(DiagramEdge(from: Self.relaunch, to: Self.root, lines: [14], stale: true)))
        // warm() still exists but no longer calls: not a caller, not stale, gone.
        #expect(after.node(Self.warm) == nil)
        #expect(!after.edges.contains { $0.from == Self.warm })

        // A diagram aimed elsewhere carries nothing over.
        var other = spec
        other.direction = .both
        #expect(try await build(other, previous: after).node(Self.relaunch) == nil)

        // The symbol back in its file: a caller again, not stale.
        try write("Sources/Lib/Registry.swift", Self.registryA)
        try write(".epoch", "a")
        let restored = try await build(spec, previous: after)
        #expect(restored.node(Self.relaunch)?.isStale == false)
        #expect(restored.nodes.filter(\.isStale).isEmpty)
    }

    @Test func codeMovedSinceTheLastBuildIsShownWhereItIsNow() async throws {
        // sourcekit-lsp places items and calls where the last build's index saw them.
        try write("Sources/Lib/Registry.swift", "// one\n// two\n// three\n" + Self.registryA)
        try write(".epoch", "d")
        var spec = Self.callers
        spec.expanded = [Self.replay]
        let graph = try await build(spec)
        let replay = try #require(graph.node(Self.replay))
        #expect(replay.line == 11 && replay.lines == LineRange(start: 11, end: 13))
        #expect(replay.excerpt == [DiagramExcerptLine(line: 12, text: "Spool.read(from: root, limit: 1).count")])
        #expect(graph.edges.contains(DiagramEdge(from: Self.relaunch, to: Self.root, lines: [17])))
        #expect(graph.edges.contains(DiagramEdge(from: Self.open, to: Self.replay, lines: [8])))
    }

    @Test func aRootWhoseSymbolIsGoneKeepsTheGraphWithTheRootStale() async throws {
        let before = try await build(Self.callers)
        try write("Sources/Lib/Spool.swift", "public enum Spool {}\n")
        try write(".epoch", "c")
        let after = try await build(Self.callers, previous: before)
        #expect(after.node(Self.root)?.isStale == true)
        #expect(after.nodes.map(\.id) == before.nodes.map(\.id))
        #expect(after.error == "Spool.read(from:limit:) is no longer declared in Sources/Lib/Spool.swift")
    }

    @Test func aServerWithoutCallHierarchySaysSoInsteadOfAnEmptyGraph() async throws {
        let script = dir.appendingPathComponent(".replay.py")
        let service = LanguageService(configs: [Self.server(script, capabilities: #"{"definitionProvider": true}"#)])
        let graph = try await CallGraphBuilder.build(Self.callers, boardRoot: dir, previous: nil, languages: service)
        #expect(graph.nodes.isEmpty)
        #expect(graph.error == "/usr/bin/python3 does not answer call hierarchy requests (no callHierarchyProvider in its capabilities)")
        await #expect(throws: LSPError.unsupportedRequest("/usr/bin/python3 does not answer type definitions requests (no typeDefinitionProvider in its capabilities)")) {
            try await service.typeDefinition(file: self.dir.appendingPathComponent("Sources/Lib/Spool.swift"), boardRoot: self.dir, at: LSPPosition(line: 2, character: 23))
        }
        await service.stopAll()
    }

    // MARK: Mentions and arrows

    func board(with graph: DiagramGraph) -> (Board, CanvasObject) {
        let board = Board(id: "brd_diagram", root: dir)
        var props = (try? JSONValue.encode(["path": "Sources/Lib/Spool.swift", "symbol": "Spool.read", "direction": "incoming"])) ?? .object([:])
        props = props.merging(.object(["depth": .number(1), "graph": graph.json]))
        let diagram = board.create(type: .diagram, props: props, frame: Frame(x: 100, y: 100, w: 900, h: 600))
        return (board, diagram)
    }

    @Test func aNodeMentionNamesItsSymbolAndPathLineAndCarriesItsCode() async throws {
        let graph = try await build(Self.callers)
        let (board, diagram) = board(with: graph)
        let replay = try #require(graph.node(Self.replay))

        let whole = replay.mention(in: diagram.id)
        #expect(MentionContext.label(for: whole, on: board) == "Sources/Lib/Registry.swift:8-10 Registry.replay(on:)")
        let resolved = await MentionContext.resolve(Mention(id: "men_1", target: whole, label: "", stagedAt: Date()), index: 1, on: board)
        let lines = resolved.summary.split(separator: "\n").map(String.init)
        #expect(lines.first == "[1] code Sources/Lib/Registry.swift:8-10 (symbol Registry.replay(on:)) · tile \(diagram.id)")
        #expect(lines.contains { $0.contains("func replay(on root: String) -> Int {") })

        // The excerpt line under the pointer: that call, still named by its symbol.
        let call = replay.mention(in: diagram.id, excerptLine: 9)
        #expect(MentionContext.label(for: call, on: board) == "Sources/Lib/Registry.swift:9 Registry.replay(on:)")
    }

    @Test func anArrowBoundToANodeEndsAtThatNodesBoxAndFollowsIt() async throws {
        let graph = try await build(Self.callers)
        let (board, diagram) = board(with: graph)
        let arrow = board.create(type: .arrow, props: .object([
            "from": .object(["point": .array([.number(-400), .number(0)])]),
            "to": .object(["object": .string(diagram.id), "node": .string(Self.warm)]),
        ]))
        func end() throws -> CGPoint { try #require(board.geometry.routes()[arrow.id]?.last) }
        let box = try #require(DiagramLayout.canvasRect(of: Self.warm, frame: diagram.frame, props: diagram.props))
        // Arrow ends stop a few points short of what they point at.
        #expect(box.insetBy(dx: -6, dy: -6).contains(try end()))
        #expect(!box.insetBy(dx: 2, dy: 2).contains(try end()))
        #expect(box.maxY < diagram.frame.rect.maxY && box.minX > diagram.frame.rect.minX)

        // The tile grows: the node moves with the fitted layout, and so does the arrow's end.
        try board.update(diagram.id, frame: Frame(x: 100, y: 100, w: 1400, h: 900))
        let moved = try #require(DiagramLayout.canvasRect(of: Self.warm, frame: try board.object(diagram.id).frame, props: diagram.props))
        #expect(moved != box)
        #expect(moved.insetBy(dx: -6, dy: -6).contains(try end()))
    }
}
