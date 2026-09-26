import Foundation

/// All open boards in the app, plus event fan-out to socket subscribers.
@MainActor
public final class BoardRegistry {
    public private(set) var boards: [BoardID: Board] = [:]
    /// Board of the key window; the default target when a call names no board or caller.
    public var frontmost: BoardID?
    public let store: BoardStore
    private var subscribers: [(connection: SocketServer.Connection, board: BoardID?, events: Set<String>?)] = []
    /// App-level observer for every board's events (UI reconciliation). Socket subscribers are fed separately.
    public var onEvent: ((Board, BoardEvent) -> Void)?
    /// The router's own observer (agent.wait), kept apart from the app-level hook.
    var routerHook: ((Board, BoardEvent) -> Void)?

    public init(store: BoardStore = BoardStore()) {
        self.store = store
    }

    @discardableResult
    public func open(root: URL) -> Board {
        let id = BoardStore.boardID(for: root)
        if let existing = boards[id] { return existing }
        let board = store.load(root: root)
        board.onEvent = { [weak self, weak board] event in
            guard let self, let board else { return }
            self.onEvent?(board, event)
            self.routerHook?(board, event)
            self.broadcast(event, board: board.id)
        }
        boards[id] = board
        frontmost = frontmost ?? id
        return board
    }

    public func close(_ id: BoardID) {
        if let board = boards.removeValue(forKey: id) { store.save(board) }
        if frontmost == id { frontmost = boards.keys.first }
    }

    public func board(containing object: ObjectID) -> Board? {
        boards.values.first { $0.objects[object] != nil }
    }

    func subscribe(_ connection: SocketServer.Connection, board: BoardID?, events: [String]?) {
        subscribers.append((connection, board, events.map(Set.init)))
    }

    private func broadcast(_ event: BoardEvent, board: BoardID) {
        subscribers.removeAll { !$0.connection.isOpen }
        let message: JSONValue = .object(["event": .string(event.name), "board": .string(board), "data": event.data])
        for subscriber in subscribers {
            if let filter = subscriber.board, filter != board { continue }
            if let events = subscriber.events, !events.contains(event.name) { continue }
            subscriber.connection.send(message)
        }
    }
}

/// Maps schema/canvas-api.json methods onto boards. App-level capabilities (object images,
/// attention markers, pasting into terminals) are injected as closures by the app.
@MainActor
public final class ApiRouter {
    public struct Failure: Error {
        public var code: String
        public var message: String

        public init(_ code: String, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    public let registry: BoardRegistry
    public var objectImage: ((Board, ObjectID) -> Data?)?
    public var raiseAttention: ((Board, ObjectID, String?) -> Void)?
    /// Types text into a terminal tile (bracketed paste) and presses Enter; false when the surface isn't attached.
    public var submitToTerminal: ((Board, ObjectID, String) -> Bool)?
    /// PNG of the board's window as currently shown.
    public var snapshotBoard: ((Board) -> (png: Data, width: Int, height: Int)?)?
    /// The last `lines` lines of a terminal tile's session text (a `TerminalTail`), read and
    /// trimmed off the main actor; nil when the session doesn't exist.
    public var readTerminal: ((Board, ObjectID, _ lines: Int) async -> (text: String, lines: Int)?)?
    public static let schemaVersion = 1
    static let readLinesDefault = 100
    static let readLinesMax = 2000

    /// Terminals prompted through the API that have not yet reported work; `agent.wait` must not
    /// answer from the pre-prompt state.
    private var pendingPrompts: Set<ObjectID> = []
    private var waiters: [Waiter] = []

    private struct Waiter {
        let token = UUID()
        let id: JSONValue
        let connection: SocketServer.Connection
        let tile: ObjectID
        let until: Set<String>
    }

    public init(registry: BoardRegistry) {
        self.registry = registry
        registry.routerHook = { [weak self] board, event in self?.observe(event, on: board) }
    }

    /// Entry point for SocketServer. Returns the response line, or nil when the reply is deferred
    /// (agent.wait) or the connection became an event stream.
    public func handle(_ request: JSONValue, connection: SocketServer.Connection) async -> JSONValue? {
        let id = request["id"] ?? .null
        guard let method = request["method"]?.string else {
            return Self.error(id, Failure("invalid_params", "missing method"))
        }
        let params = request["params"] ?? .object([:])
        do {
            if method == "events.subscribe" {
                registry.subscribe(connection, board: params["board"]?.string, events: params["events"]?.array?.compactMap(\.string))
                connection.send(.object(["id": id, "ok": .bool(true), "result": .object([:])]))
                return nil
            }
            if method == "agent.wait" { return try wait(id, params, connection) }
            if method == "agent.read" { return Self.ok(id, try await read(params)) }
            if method == "tray.drain" {
                let drained = try await board(params).drain(peek: params["peek"]?.bool ?? false)
                return Self.ok(id, .object(["mentions": try JSONValue.encode(drained.mentions), "context": .string(drained.context)]))
            }
            return Self.ok(id, try dispatch(method, params))
        } catch let failure as Failure {
            return Self.error(id, failure)
        } catch let error as BoardError {
            switch error {
            case .notFound(let message): return Self.error(id, Failure("not_found", message))
            case .conflict(let message): return Self.error(id, Failure("conflict", message))
            case .invalidParams(let message): return Self.error(id, Failure("invalid_params", message))
            }
        } catch {
            return Self.error(id, Failure("invalid_params", String(describing: error)))
        }
    }

    static func ok(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["id": id, "ok": .bool(true), "result": result])
    }

    static func error(_ id: JSONValue, _ failure: Failure) -> JSONValue {
        .object(["id": id, "ok": .bool(false), "error": .object(["code": .string(failure.code), "message": .string(failure.message)])])
    }

    // MARK: agent.wait

    private func wait(_ id: JSONValue, _ p: JSONValue, _ connection: SocketServer.Connection) throws -> JSONValue? {
        let (board, terminal) = try agentTile(try string(p, "target"))
        let until = Set(p["until"]?.array?.compactMap(\.string) ?? ["idle", "done", "blocked"])
        let waiter = Waiter(id: id, connection: connection, tile: terminal.id, until: until)
        if let reply = reply(to: waiter, on: board) { return reply }
        waiters.append(waiter)
        if let timeout = p["timeoutMs"]?.int {
            let token = waiter.token
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, timeout))) { [weak self] in
                MainActor.assumeIsolated { self?.expire(token) }
            }
        }
        return nil
    }

    /// The response for a satisfied waiter, or nil while it must keep waiting.
    private func reply(to waiter: Waiter, on board: Board) -> JSONValue? {
        guard let terminal = board.objects[waiter.tile] else {
            return Self.error(waiter.id, Failure("not_found", "terminal \(waiter.tile) was closed"))
        }
        guard !pendingPrompts.contains(waiter.tile), waiter.until.contains(Self.state(of: terminal)) else { return nil }
        return Self.ok(waiter.id, .object(["agent": agentEntry(terminal, on: board)]))
    }

    private func observe(_ event: BoardEvent, on board: Board) {
        let tile: ObjectID
        switch event {
        case .agentLifecycle(let id, let lifecycle):
            tile = id
            let state = lifecycle["state"]?.string
            if lifecycle == .null || state == LifecycleState.working.rawValue || state == LifecycleState.blocked.rawValue {
                pendingPrompts.remove(id)
            }
        case .objectDeleted(let id):
            tile = id
            pendingPrompts.remove(id)
        default:
            return
        }
        waiters.removeAll { waiter in
            guard waiter.connection.isOpen else { return true }
            guard waiter.tile == tile, let reply = reply(to: waiter, on: board) else { return false }
            waiter.connection.send(reply)
            return true
        }
    }

    private func expire(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.connection.send(Self.error(waiter.id, Failure("timeout", "\(waiter.tile) did not reach \(waiter.until.sorted().joined(separator: "|")) in time")))
    }

    // MARK: Agents

    static func state(of terminal: CanvasObject) -> String {
        terminal.props["lifecycle"]?["state"]?.string ?? LifecycleState.unknown.rawValue
    }

    /// A terminal tile by id, or by its user-given `name`, across all open boards.
    func agentTile(_ target: String) throws -> (Board, CanvasObject) {
        for board in registry.boards.values {
            if let object = board.objects[target], object.type == .terminal { return (board, object) }
        }
        for board in registry.boards.values {
            if let object = board.objects.values.first(where: { $0.type == .terminal && $0.props["name"]?.string == target }) { return (board, object) }
        }
        throw Failure("not_found", "no terminal tile named or with id \(target)")
    }

    func agentEntry(_ terminal: CanvasObject, on board: Board) -> JSONValue {
        let agent = terminal.props["agent"]
        let entry: [String: JSONValue] = [
            "tile": .string(terminal.id), "board": .string(board.id),
            "kind": agent?["kind"] ?? .string("unknown"),
            "name": terminal.props["name"] ?? .null,
            "sessionId": agent?["sessionId"] ?? .null,
            "lifecycle": terminal.props["lifecycle"] ?? .object(["state": .string(LifecycleState.unknown.rawValue)]),
        ]
        return .object(entry.filter { $0.value != .null })
    }

    /// `agent.read`: the tail of the session text. The read runs off the main actor (it spawns
    /// `zmx history`), and the reply stays in order because each connection is served serially.
    private func read(_ p: JSONValue) async throws -> JSONValue {
        let (board, terminal) = try agentTile(try string(p, "target"))
        let requested = p["lines"]?.int ?? Self.readLinesDefault
        guard requested >= 1 else { throw Failure("invalid_params", "lines must be at least 1") }
        guard let readTerminal else { throw Failure("unsupported", "reading terminals needs the app UI") }
        guard let tail = await readTerminal(board, terminal.id, min(requested, Self.readLinesMax)) else {
            throw Failure("unavailable", "terminal \(terminal.id) has no running session")
        }
        let current = board.objects[terminal.id] ?? terminal
        return .object([
            "agent": agentEntry(current, on: board),
            "text": .string(tail.text),
            "lines": .number(Double(tail.lines)),
        ])
    }

    func dispatch(_ method: String, _ p: JSONValue) throws -> JSONValue {
        switch method {
        case "system.ping":
            return .object(["version": .number(Double(Self.schemaVersion)), "app": .string("Canvas")])

        case "board.get":
            let board = try board(p)
            let objects = board.snapshot.objects.map(summarized)
            var result: [String: JSONValue] = [
                "board": .string(board.id), "root": .string(board.root.path),
                "revision": .number(Double(board.revision)), "objects": try JSONValue.encode(objects),
            ]
            if let since = p["since"]?.int { result["changed"] = .array(board.changed(since: since).map(JSONValue.string)) }
            return .object(result)

        case "board.list":
            // Open boards are the truth for root and contents: a moved worktree's new root and any
            // unsaved edits aren't on disk yet. The save time stays the disk's.
            var stored = registry.store.list()
            for board in registry.boards.values {
                let index: Int
                if let found = stored.firstIndex(where: { $0.id == board.id }) {
                    index = found
                } else {
                    stored.append(.init(id: board.id, root: "", archived: false, updatedAt: nil, objectCount: 0))
                    index = stored.count - 1
                }
                stored[index].root = board.root.path
                stored[index].archived = !BoardStore.isDirectory(board.root.path)
                stored[index].objectCount = board.objects.count
            }
            let boards = stored.map { entry -> JSONValue in
                var info: [String: JSONValue] = [
                    "board": .string(entry.id), "root": .string(entry.root), "archived": .bool(entry.archived),
                    "open": .bool(registry.boards[entry.id] != nil), "objects": .number(Double(entry.objectCount)),
                ]
                if let updatedAt = entry.updatedAt { info["updatedAt"] = .string(updatedAt.formatted(.iso8601)) }
                return .object(info)
            }
            return .object(["boards": .array(boards)])

        case "board.export":
            let board = try board(p)
            let url = board.absoluteURL(p["path"]?.string ?? ".canvas/board.json").standardizedFileURL
            do {
                try BoardStore.export(board, to: url)
            } catch {
                throw Failure("unavailable", "cannot write \(url.path): \(error.localizedDescription)")
            }
            return .object(["path": .string(url.path), "objects": .number(Double(board.objects.count))])

        case "object.get":
            let id = try string(p, "id")
            let board = try board(forObject: id)
            let object = try board.object(id)
            var result: [String: JSONValue] = ["object": try JSONValue.encode(object)]
            switch p["as"]?.string ?? "raw" {
            case "graph": result["graph"] = graph(of: object, on: board)
            case "image":
                guard let data = objectImage?(board, id) else { throw Failure("unsupported", "object images are not available for \(object.type.rawValue) tiles yet") }
                result["pngBase64"] = .string(data.base64EncodedString())
            default: break
            }
            return .object(result)

        case "object.create":
            let board = try board(p)
            guard let type = ObjectType(rawValue: try string(p, "type")) else { throw Failure("invalid_params", "unknown object type") }
            guard let props = p["props"], props.object != nil else { throw Failure("invalid_params", "props must be an object") }
            let frame = try p["frame"].map { try $0.decode(Frame.self) }
            let object = board.create(type: type, props: props, frame: frame, parent: p["parent"]?.string, caller: caller(p, on: board))
            return .object(["object": try JSONValue.encode(object)])

        case "object.update":
            let id = try string(p, "id")
            let board = try board(forObject: id)
            let frame = try p["frame"].map { try $0.decode(Frame.self) }
            let object = try board.update(id, rev: p["rev"]?.int, frame: frame, props: p["props"], caller: caller(p, on: board))
            return .object(["object": try JSONValue.encode(object)])

        case "object.delete":
            let id = try string(p, "id")
            try board(forObject: id).delete(id)
            return .object([:])

        case "tray.list":
            return .object(["mentions": try JSONValue.encode(try board(p).tray)])

        case "tray.stage":
            guard let target = p["target"] else { throw Failure("invalid_params", "missing target") }
            let mention = try board(p).stage(try target.decode(MentionTarget.self))
            return .object(["mention": try JSONValue.encode(mention)])

        case "tray.unstage":
            let id = try string(p, "id")
            guard let board = registry.boards.values.first(where: { $0.tray.contains { $0.id == id } }) else { throw BoardError.notFound("mention \(id)") }
            try board.unstage(id)
            return .object([:])

        case "tray.commit":
            try board(p).commit(p["ids"]?.array?.compactMap(\.string) ?? [])
            return .object([:])

        case "agent.report":
            let tile = try string(p, "tile")
            guard let state = LifecycleState(rawValue: try string(p, "state")) else { throw Failure("invalid_params", "unknown state") }
            try board(forObject: tile).reportLifecycle(tile: tile, kind: try string(p, "kind"), state: state, message: p["message"]?.string, seq: p["seq"]?.int, source: p["source"]?.string)
            return .object([:])

        case "agent.report_session":
            let tile = try string(p, "tile")
            try board(forObject: tile).reportSession(tile: tile, kind: try string(p, "kind"), sessionId: p["sessionId"]?.string, sessionPath: p["sessionPath"]?.string)
            return .object([:])

        case "agent.release":
            let tile = try string(p, "tile")
            try board(forObject: tile).releaseAgent(tile: tile)
            return .object([:])

        case "agent.list":
            var agents: [JSONValue] = []
            for board in registry.boards.values {
                for object in board.objects.values where object.type == .terminal && object.props["agent"]?["kind"]?.string != nil {
                    agents.append(agentEntry(object, on: board))
                }
            }
            return .object(["agents": .array(agents)])

        case "follow.report":
            let tile = try string(p, "tile")
            let range = try p["range"].map { try $0.decode(LineRange.self) }
            try board(forObject: tile).follow(tile: tile, path: try string(p, "path"), range: range, action: try string(p, "action"))
            return .object([:])

        case "view.attention":
            let id = try string(p, "id")
            let board = try board(forObject: id)
            guard let raiseAttention else { throw Failure("unsupported", "attention markers need the app UI") }
            raiseAttention(board, id, p["message"]?.string)
            return .object([:])

        case "view.snapshot":
            let board = try board(p)
            guard let snapshotBoard else { throw Failure("unsupported", "snapshots need the app UI") }
            guard let shot = snapshotBoard(board) else { throw Failure("unavailable", "board \(board.id) has no window") }
            return .object(["pngBase64": .string(shot.png.base64EncodedString()), "width": .number(Double(shot.width)), "height": .number(Double(shot.height))])

        case "agent.prompt":
            let (board, terminal) = try agentTile(try string(p, "target"))
            guard let submitToTerminal else { throw Failure("unsupported", "prompting needs the app UI") }
            guard submitToTerminal(board, terminal.id, try string(p, "text")) else {
                throw Failure("unavailable", "terminal \(terminal.id) has no attached surface")
            }
            pendingPrompts.insert(terminal.id)
            return .object(["agent": agentEntry(terminal, on: board)])

        default:
            throw Failure("invalid_params", "unknown method \(method)")
        }
    }

    // MARK: Helpers

    func string(_ p: JSONValue, _ key: String) throws -> String {
        guard let value = p[key]?.string else { throw Failure("invalid_params", "missing \(key)") }
        return value
    }

    /// Target board: explicit `board`, else the caller tile's board, else the frontmost board.
    func board(_ p: JSONValue) throws -> Board {
        if let id = p["board"]?.string {
            guard let board = registry.boards[id] else { throw BoardError.notFound("board \(id)") }
            return board
        }
        if let caller = p["caller"]?.string, let board = registry.board(containing: caller) { return board }
        if let id = registry.frontmost, let board = registry.boards[id] { return board }
        throw Failure("not_found", "no open board")
    }

    func board(forObject id: ObjectID) throws -> Board {
        guard let board = registry.board(containing: id) else { throw BoardError.notFound("object \(id)") }
        return board
    }

    /// A caller is only honored when it is a terminal tile on this board.
    func caller(_ p: JSONValue, on board: Board) -> ObjectID? {
        guard let caller = p["caller"]?.string, board.objects[caller]?.type == .terminal else { return nil }
        return caller
    }

    /// Heavy props (HTML source, long markdown) are trimmed in the manifest; object.get returns them whole.
    func summarized(_ object: CanvasObject) -> CanvasObject {
        var copy = object
        if object.type == .html, let html = object.props["html"]?.string {
            copy.props = object.props.merging(.object(["html": .string("(\(html.utf8.count) bytes, use object.get)")]))
        }
        if object.type == .note, let markdown = object.props["markdown"]?.string, markdown.count > 400 {
            copy.props = object.props.merging(.object(["markdown": .string(String(markdown.prefix(400)) + "…")]))
        }
        return copy
    }

    func graph(of object: CanvasObject, on board: Board) -> JSONValue {
        let others = board.objects.values.filter { $0.id != object.id && $0.type != .arrow }
        let encloses = others.filter { object.frame.contains($0.frame) }.map(\.id).sorted()
        let enclosedBy = others.filter { $0.frame.contains(object.frame) }.map(\.id).sorted()
        let overlaps = others.filter { $0.frame.intersects(object.frame) && !encloses.contains($0.id) && !enclosedBy.contains($0.id) }.map(\.id).sorted()
        var arrowsOut: [JSONValue] = []
        var arrowsIn: [JSONValue] = []
        for arrow in board.objects.values where arrow.type == .arrow {
            let relation = arrow.props["relation"] ?? .null
            if arrow.props["from"]?["object"]?.string == object.id, let to = arrow.props["to"]?["object"]?.string {
                arrowsOut.append(.object(["arrow": .string(arrow.id), "to": .string(to), "relation": relation]))
            }
            if arrow.props["to"]?["object"]?.string == object.id, let from = arrow.props["from"]?["object"]?.string {
                arrowsIn.append(.object(["arrow": .string(arrow.id), "from": .string(from), "relation": relation]))
            }
        }
        return .object([
            "encloses": .array(encloses.map(JSONValue.string)),
            "enclosedBy": .array(enclosedBy.map(JSONValue.string)),
            "overlaps": .array(overlaps.map(JSONValue.string)),
            "arrowsOut": .array(arrowsOut),
            "arrowsIn": .array(arrowsIn),
        ])
    }
}
