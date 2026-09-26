import Foundation
import Testing
import CanvasCore

/// agent.read, board.list, and board.export over the real socket.
@MainActor
final class AgentBoardApiTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    let server: SocketServer
    let board: Board
    /// Session text per terminal tile; tiles without an entry have no session.
    var sessions: [ObjectID: String] = [:]

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        board = registry.open(root: dir.appendingPathComponent("root"))
        let router = ApiRouter(registry: registry)
        self.router = router
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        router.readTerminal = { [unowned self] _, tile in sessions[tile] }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func call(_ method: String, _ params: String = "{}") async throws -> JSONValue {
        let client = try LineClient(path: dir.appendingPathComponent("s").path)
        client.send(#"{"id":"1","method":"\#(method)","params":\#(params)}"#)
        return try await client.next()
    }

    func terminal(name: String? = nil) -> ObjectID {
        var props: [String: JSONValue] = ["cwd": .string(dir.path)]
        if let name { props["name"] = .string(name) }
        return board.create(type: .terminal, props: .object(props)).id
    }

    // MARK: agent.read

    @Test func readReturnsTheTailWithoutTrailingBlankLines() async throws {
        let tile = terminal()
        sessions[tile] = (1...150).map { "line \($0)   " }.joined(separator: "\n") + "\n\n   \n"
        let reply = try await call("agent.read", #"{"target":"\#(tile)","lines":3}"#)
        #expect(reply["result"]?["text"] == .string("line 148\nline 149\nline 150"))
        #expect(reply["result"]?["lines"] == .number(3))
        #expect(reply["result"]?["agent"]?["tile"] == .string(tile))

        let defaulted = try await call("agent.read", #"{"target":"\#(tile)"}"#)
        #expect(defaulted["result"]?["lines"] == .number(100))
        #expect(defaulted["result"]?["text"]?.string?.hasPrefix("line 51\n") == true)
    }

    @Test func readResolvesAgentsByName() async throws {
        _ = terminal(name: "reviewer-a")
        let reviewer = terminal(name: "reviewer")
        sessions[reviewer] = "ready"
        let reply = try await call("agent.read", #"{"target":"reviewer"}"#)
        #expect(reply["result"]?["agent"]?["tile"] == .string(reviewer))
        #expect(reply["result"]?["text"] == .string("ready"))
    }

    @Test func readCapsLongTails() async throws {
        let tile = terminal()
        sessions[tile] = (1...5000).map(String.init).joined(separator: "\n")
        let reply = try await call("agent.read", #"{"target":"\#(tile)","lines":100000}"#)
        #expect(reply["result"]?["lines"] == .number(2000))
        #expect(reply["result"]?["text"]?.string?.hasPrefix("3001\n") == true)
    }

    @Test func readFailsForUnknownTargetsNonTerminalsAndMissingSessions() async throws {
        #expect(try await call("agent.read", #"{"target":"nobody"}"#)["error"]?["code"] == .string("not_found"))
        let note = board.create(type: .note, props: .object(["markdown": .string("x")])).id
        #expect(try await call("agent.read", #"{"target":"\#(note)"}"#)["error"]?["code"] == .string("not_found"))
        let tile = terminal()
        #expect(try await call("agent.read", #"{"target":"\#(tile)"}"#)["error"]?["code"] == .string("unavailable"))
        sessions[tile] = "x"
        #expect(try await call("agent.read", #"{"target":"\#(tile)","lines":0}"#)["error"]?["code"] == .string("invalid_params"))
    }

    // MARK: board.list

    @Test func listMarksBoardsWhoseRootIsGoneAsArchived() async throws {
        board.create(type: .note, props: .object(["markdown": .string("kept")]))
        let worktree = dir.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let doomed = registry.open(root: worktree)
        doomed.create(type: .note, props: .object(["markdown": .string("a")]))
        doomed.create(type: .note, props: .object(["markdown": .string("b")]))
        registry.store.flush([doomed])
        registry.close(doomed.id)
        try FileManager.default.removeItem(at: worktree)
        let sub = dir.appendingPathComponent("root/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fresh = registry.open(root: sub)

        let boards = try #require(try await call("board.list")["result"]?["boards"]?.array)
        let byID = Dictionary(uniqueKeysWithValues: boards.map { ($0["board"]?.string ?? "", $0) })
        #expect(byID.count == 3)
        #expect(byID[doomed.id]?["archived"] == .bool(true))
        #expect(byID[doomed.id]?["open"] == .bool(false))
        #expect(byID[doomed.id]?["objects"] == .number(2))
        #expect(byID[doomed.id]?["updatedAt"]?.string != nil)
        #expect(byID[board.id]?["archived"] == .bool(false))
        #expect(byID[board.id]?["open"] == .bool(true))
        #expect(byID[board.id]?["objects"] == .number(1), "unsaved changes of open boards are counted")
        #expect(byID[fresh.id]?["updatedAt"] == nil, "a board never saved has no save time")
        #expect(byID[fresh.id]?["archived"] == .bool(false))
    }

    // MARK: board.export

    @Test func exportWritesAReadableSnapshotThatLoadsBack() async throws {
        let tile = terminal()
        let note = board.create(type: .note, props: .object(["markdown": .string("# Plan ✓\nsee src/a/b.ts:12")]), caller: tile)
        _ = try board.stage(.object(note.id))

        let reply = try await call("board.export")
        let path = dir.appendingPathComponent("root/.canvas/board.json").standardizedFileURL.path
        #expect(reply["result"]?["path"] == .string(path))
        #expect(reply["result"]?["objects"] == .number(2))

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\n  \"id\" : \"\(board.id)\""), "pretty-printed")
        #expect(text.contains("src/a/b.ts:12"), "slashes unescaped for readable diffs")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(BoardSnapshot.self, from: data)
        #expect(snapshot.tray == nil, "the personal tray stays out of the repo")
        let restored = Board(snapshot: snapshot)
        #expect(restored.id == board.id)
        #expect(Set(restored.objects.keys) == Set(board.objects.keys))
        #expect(restored.objects[note.id]?.props == note.props)
        #expect(restored.objects[note.id]?.frame == note.frame)
        #expect(restored.objects[note.id]?.createdBy == .agent(tile: tile))
    }

    @Test func exportHonorsRelativeAndAbsolutePaths() async throws {
        board.create(type: .note, props: .object(["markdown": .string("x")]))
        let relative = try await call("board.export", #"{"path":"docs/canvas.json"}"#)
        #expect(relative["result"]?["path"] == .string(dir.appendingPathComponent("root/docs/canvas.json").standardizedFileURL.path))
        let absolute = dir.appendingPathComponent("elsewhere/b.json").path
        _ = try await call("board.export", #"{"path":"\#(absolute)"}"#)
        #expect(FileManager.default.fileExists(atPath: absolute))
    }
}
