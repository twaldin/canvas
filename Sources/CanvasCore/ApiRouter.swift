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
        board.activity.record(.restart, actor: .system, rev: board.revision,
                              summary: "Canvas started (pid \(ProcessInfo.processInfo.processIdentifier)); board opened with \(board.objects.count) objects")
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
    public var raiseAttention: ((Board, ObjectID, String?) -> Void)?
    /// Removes an object's attention marker; false when it had none.
    public var clearAttention: ((Board, ObjectID) -> Bool)?
    /// Types text into a terminal tile (bracketed paste) and presses Enter; false when the surface isn't attached.
    public var submitToTerminal: ((Board, ObjectID, String) -> Bool)?
    /// The board's window as currently shown, encoded in `format`, with the viewport it shows.
    public var snapshotBoard: ((Board, ImageFormat) -> (output: RenderOutput, viewport: Viewport)?)?
    /// Offscreen render for `view.render`; throws `Failure` for bad targets.
    public var renderView: ((Board, RenderRequest, ImageFormat) async throws -> RenderOutput)?
    /// What the board's window shows; nil when it has none.
    public var viewState: ((Board) -> ViewState?)?
    /// The last `lines` lines of a terminal tile's session text (a `TerminalTail`), read and
    /// trimmed off the main actor; nil when the session doesn't exist.
    public var readTerminal: ((Board, ObjectID, _ lines: Int) async -> (text: String, lines: Int)?)?
    /// Opens a directory's board in the UI (a tab of the frontmost board window), selecting its tab when asked.
    public var openBoard: ((URL, _ select: Bool) -> Board)?
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
            if method == "view.render" { return Self.ok(id, try await render(params)) }
            if method == "view.snapshot" { return Self.ok(id, try await snapshot(params)) }
            if method == "tray.drain" {
                let drained = try await board(params).drain(peek: params["peek"]?.bool ?? false)
                return Self.ok(id, .object(["mentions": try JSONValue.encode(drained.mentions), "context": .string(drained.context)]))
            }
            switch method {
            case "object.measure": return Self.ok(id, try await measure(params))
            case "object.batch": return Self.ok(id, try await batch(params))
            case "layout.check": return Self.ok(id, try await check(params))
            case "object.create", "object.update":
                return Self.ok(id, try dispatch(method, try fitted(method, params, size: try await fitSize(method, params))))
            default: break
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
        } catch let failure as ObjectMeasure.Failure {
            switch failure {
            case .unsupported(let message): return Self.error(id, Failure("unsupported", message))
            case .unavailable(let message): return Self.error(id, Failure("unavailable", message))
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

    // MARK: Images

    /// `view.render`: parse the target, render offscreen in the app, then deliver the image.
    private func render(_ p: JSONValue) async throws -> JSONValue {
        let board: Board
        let target: RenderTarget
        switch p["target"] {
        case .string(let id)?:
            board = try p["board"] == nil ? self.board(forObject: id) : self.board(p)
            target = .objects([id])
        case .array(let values)?:
            let ids = values.compactMap(\.string)
            guard !ids.isEmpty, ids.count == values.count else { throw Failure("invalid_params", "target list must be object ids") }
            board = try p["board"] == nil ? self.board(forObject: ids[0]) : self.board(p)
            target = .objects(ids)
        case .object?:
            board = try self.board(p)
            let rect = try p["target"]!.decode(Frame.self)
            guard rect.w > 0, rect.h > 0 else { throw Failure("invalid_params", "target rect must have a positive size") }
            target = .rect(rect)
        default:
            throw Failure("invalid_params", "target must be an object id, a list of ids, or a rect {x, y, w, h}")
        }
        if case .objects(let ids) = target {
            for id in ids where board.objects[id] == nil { throw Failure("not_found", "object \(id) is not on board \(board.id)") }
        }
        let scale = p["scale"]?.number ?? 1
        guard (0.1...4).contains(scale) else { throw Failure("invalid_params", "scale must be between 0.1 and 4") }
        let exclude = try Set((p["exclude"]?.array ?? []).map { value in
            guard let type = value.string.flatMap(ObjectType.init(rawValue:)) else { throw Failure("invalid_params", "exclude takes object types, not \(value)") }
            return type
        })
        let timeout = min(max(p["timeoutMs"]?.int ?? 8000, 0), 60_000)
        let request = RenderRequest(target: target, scale: scale, full: p["full"]?.bool ?? false, exclude: exclude,
                                    padding: max(0, p["padding"]?.number ?? 0), timeout: .milliseconds(timeout))
        let (format, out) = try imageDestination(p)
        guard let renderView else { throw Failure("unsupported", "rendering needs the app UI") }
        let output = try await renderView(board, request, format)
        var result = try await deliver(output, to: out)
        result["canvasRect"] = RenderMath.json(output.canvasRect)
        result["scale"] = .number(output.scale)
        result["objects"] = .array(output.objects.map(\.json))
        return .object(result)
    }

    /// `view.snapshot`: the window as shown, with the viewport it shows.
    private func snapshot(_ p: JSONValue) async throws -> JSONValue {
        let board = try board(p)
        let (format, out) = try imageDestination(p)
        guard let snapshotBoard else { throw Failure("unsupported", "snapshots need the app UI") }
        guard let shot = snapshotBoard(board, format) else { throw Failure("unavailable", "board \(board.id) has no window") }
        var result = try await deliver(shot.output, to: out)
        result["viewport"] = shot.viewport.json
        result["scale"] = .number(shot.output.scale)
        result["objects"] = .array(shot.output.objects.map(\.json))
        return .object(result)
    }

    /// Format from `out`'s extension (which must be absolute and writable), else `format`.
    private func imageDestination(_ p: JSONValue) throws -> (ImageFormat, String?) {
        if let out = p["out"]?.string {
            guard out.hasPrefix("/") else { throw Failure("invalid_params", "out must be an absolute path (clients resolve relative paths)") }
            guard let format = ImageFormat(path: out) else { throw Failure("invalid_params", "out must end in .png, .jpg, or .jpeg") }
            return (format, out)
        }
        guard let name = p["format"]?.string else { return (.png, nil) }
        guard let format = ImageFormat(rawValue: name) else { throw Failure("invalid_params", "format must be png or jpeg") }
        return (format, nil)
    }

    private func deliver(_ output: RenderOutput, to out: String?) async throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "format": .string(output.format.rawValue), "width": .number(Double(output.width)), "height": .number(Double(output.height)),
        ]
        guard let out else {
            result["imageBase64"] = .string(output.image.base64EncodedString())
            return result
        }
        let image = output.image
        let failure: String? = await offPool {
            do {
                try image.write(to: URL(fileURLWithPath: out), options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if let failure { throw Failure("unavailable", "cannot write \(out): \(failure)") }
        result["path"] = .string(out)
        return result
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

        case "board.history":
            let board = try board(p)
            let since: ActivityLog.Since?
            switch p["since"] {
            case .number(let value): since = .seq(Int(value))
            case .string(let text):
                guard let time = try? Date(text, strategy: .iso8601) else { throw Failure("invalid_params", "since must be a seq cursor or an ISO 8601 time") }
                since = .time(time)
            case nil, .null?: since = nil
            default: throw Failure("invalid_params", "since must be a seq cursor or an ISO 8601 time")
            }
            let limit = min(max(p["limit"]?.int ?? 100, 1), board.activity.capacity)
            var kinds: Set<ActivityEntry.Kind>?
            if let names = p["kinds"]?.array {
                kinds = Set(try names.map { name in
                    guard let kind = name.string.flatMap(ActivityEntry.Kind.init(rawValue:)) else { throw Failure("invalid_params", "unknown history kind \(name)") }
                    return kind
                })
            }
            let page = board.activity.query(since: since, limit: limit, kinds: kinds)
            return .object([
                "board": .string(board.id), "cursor": .number(Double(page.cursor)), "entries": .array(page.entries.map(\.json)),
                "truncated": .bool(page.truncated), "restarted": .bool(page.restarted),
            ])

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

        case "board.open":
            guard let path = p["root"]?.string, !path.isEmpty else { throw Failure("invalid_params", "root is required") }
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw Failure("invalid_params", "root must be an absolute path (or start with ~)") }
            let root = URL(fileURLWithPath: expanded).standardizedFileURL
            guard BoardStore.isDirectory(root.path) else { throw Failure("not_found", "no directory at \(root.path)") }
            let board = openBoard?(root, p["select"]?.bool ?? false) ?? registry.open(root: root)
            return .object(["board": .string(board.id), "root": .string(board.root.path), "objects": .number(Double(board.objects.count))])

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
            case "raw": break
            case "image": throw Failure("invalid_params", "object.get no longer renders images: use view.render with target \(id)")
            case let other: throw Failure("invalid_params", "unknown as: \(other)")
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
            let board = try board(forObject: id)
            try board.delete(id, caller: caller(p, on: board))
            return .object([:])

        case "layout.place":
            let id = try string(p, "id")
            let board = try board(forObject: id)
            let near = try string(p, "near")
            guard board.objects[near] != nil else { throw BoardError.notFound("object \(near) on this board") }
            let frames = try board.place(id, near: near, side: try option(p, "side", Layout.Side.self) ?? .right, gap: p["gap"]?.number ?? Layout.defaultGap,
                                         align: try option(p, "align", Layout.Align.self) ?? .start, caller: caller(p, on: board))
            return .object(["frames": try JSONValue.encode(frames)])

        case "layout.stack":
            guard let ids = p["ids"]?.array?.compactMap(\.string), !ids.isEmpty else { throw Failure("invalid_params", "ids must be a non-empty array of object ids") }
            let board = try board(forObject: ids[0])
            for id in ids where board.objects[id] == nil { throw BoardError.notFound("object \(id) on this board") }
            let origin = try p["origin"].map { value -> CGPoint in
                guard let x = value["x"]?.number, let y = value["y"]?.number else { throw Failure("invalid_params", "origin needs x and y") }
                return CGPoint(x: x, y: y)
            }
            let frames = try board.stack(ids, direction: try option(p, "direction", Layout.Direction.self) ?? .row, gap: p["gap"]?.number ?? Layout.defaultGap,
                                         wrapAt: p["wrapAt"]?.number, align: try option(p, "align", Layout.Align.self) ?? .start, origin: origin, caller: caller(p, on: board))
            return .object(["frames": try JSONValue.encode(frames)])

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
            guard let raiseAttention, let clearAttention else { throw Failure("unsupported", "attention markers need the app UI") }
            if p["clear"]?.bool == true {
                _ = clearAttention(board, id)
                return .object(["id": .string(id), "active": .bool(false)])
            }
            raiseAttention(board, id, p["message"]?.string)
            return .object(["id": .string(id), "active": .bool(true)])

        case "view.get":
            let board = try board(p)
            guard let viewState else { throw Failure("unsupported", "the viewport needs the app UI") }
            guard let state = viewState(board) else { throw Failure("unavailable", "board \(board.id) has no window") }
            var result: [String: JSONValue] = [
                "board": .string(board.id), "viewport": state.viewport.json,
                "selection": .array(state.selection.map(JSONValue.string)), "visible": .bool(state.visible),
            ]
            if let target = state.promptTarget { result["promptTarget"] = .string(target) }
            if let focused = state.focused { result["focused"] = .string(focused) }
            if let group = state.enteredGroup { result["enteredGroup"] = .string(group) }
            return .object(result)

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

    // MARK: Layout

    /// An optional enum parameter; an unknown value is invalid rather than ignored.
    func option<T: RawRepresentable & CaseIterable>(_ p: JSONValue, _ key: String, _ type: T.Type) throws -> T? where T.RawValue == String {
        guard let raw = p[key]?.string else { return nil }
        guard let value = T(rawValue: raw) else {
            throw Failure("invalid_params", "\(key) must be one of \(T.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return value
    }

    /// `object.measure`: the intrinsic frame size for a type and props (notes and text wrap at
    /// `width`). Paths resolve against the caller's (or the given) board.
    private func measure(_ p: JSONValue) async throws -> JSONValue {
        guard let type = ObjectType(rawValue: try string(p, "type")) else { throw Failure("invalid_params", "unknown object type") }
        let size = try await ObjectMeasure.size(type: type, props: p["props"] ?? .object([:]), width: p["width"]?.number, root: try board(p).root)
        return .object(["w": .number(size.width), "h": .number(size.height)])
    }

    /// The measured size an `object.create`/`object.update` with `size: "fit"` gets; nil without
    /// `size`. Notes and text wrap at the given frame's `w` (an update keeps its current width);
    /// code takes the given `w` as its widest (default `CodeMetrics.defaultFitWidth`, also on an
    /// update, so a re-fit can widen a tile as well as narrow it).
    /// `pending` are the params of creates earlier in the same batch, for updates of `$n`.
    func fitSize(_ method: String, _ p: JSONValue, pending: [Int: JSONValue] = [:]) async throws -> CGSize? {
        guard let size = p["size"] else { return nil }
        guard size.string == "fit" else { throw Failure("invalid_params", "size must be \"fit\"") }
        let width = p["frame"]?["w"]?.number
        if method == "object.create" {
            guard let type = ObjectType(rawValue: try string(p, "type")) else { throw Failure("invalid_params", "unknown object type") }
            return try await ObjectMeasure.size(type: type, props: p["props"] ?? .object([:]), width: width, root: try board(p).root)
        }
        let id = try string(p, "id")
        let base: (type: ObjectType, props: JSONValue, width: Double?, root: URL)
        if let index = Self.reference(id) {
            guard let created = pending[index], let type = ObjectType(rawValue: try string(created, "type")) else {
                throw Failure("invalid_params", "\(id) must name an earlier create op")
            }
            base = (type, created["props"] ?? .object([:]), created["frame"]?["w"]?.number, try board(created).root)
        } else {
            let board = try board(forObject: id)
            let object = try board.object(id)
            base = (object.type, object.props, object.frame.w, board.root)
        }
        let props = p["props"].map { base.props.merging($0) } ?? base.props
        return try await ObjectMeasure.size(type: base.type, props: props, width: width ?? (base.type == .code ? nil : base.width), root: base.root)
    }

    /// Params with `size: "fit"` resolved into a whole frame: the measured size at the given (or
    /// current, or automatically placed) origin.
    func fitted(_ method: String, _ p: JSONValue, size: CGSize?) throws -> JSONValue {
        guard let size, var params = p.object else { return p }
        params.removeValue(forKey: "size")
        let origin: (x: Double, y: Double)
        if let x = p["frame"]?["x"]?.number, let y = p["frame"]?["y"]?.number {
            origin = (x, y)
        } else if method == "object.create" {
            let board = try board(p)
            let placed = board.place(width: size.width, height: size.height, near: caller(p, on: board))
            origin = (placed.x, placed.y)
        } else {
            let id = try string(p, "id")
            let current = try board(forObject: id).object(id).frame
            origin = (current.x, current.y)
        }
        params["frame"] = try JSONValue.encode(Frame(x: origin.x, y: origin.y, w: size.width, h: size.height))
        return .object(params)
    }

    /// `$n` → n, the index of an earlier batch op.
    static func reference(_ text: String) -> Int? {
        guard text.hasPrefix("$") else { return nil }
        return Int(text.dropFirst())
    }

    static let batchMethods: Set<String> = ["object.create", "object.update", "object.delete", "layout.place", "layout.stack"]

    /// `object.batch`: every op applies or none does, as one board revision and one undo step.
    /// Sizes are measured before anything changes, so nothing else interleaves with the writes.
    private func batch(_ p: JSONValue) async throws -> JSONValue {
        guard let ops = p["ops"]?.array, !ops.isEmpty else { throw Failure("invalid_params", "ops must be a non-empty array") }
        let board = try board(p)
        func prepared(_ method: String, _ raw: JSONValue) -> JSONValue {
            var params = raw.object ?? [:]
            if method == "object.create" { params["board"] = .string(board.id) }
            if params["caller"] == nil, let caller = p["caller"] { params["caller"] = caller }
            return .object(params)
        }
        var pending: [Int: JSONValue] = [:]
        var sizes: [CGSize?] = []
        for (index, op) in ops.enumerated() {
            let method = op["method"]?.string ?? ""
            guard Self.batchMethods.contains(method) else {
                throw Failure("invalid_params", "op \(index): method must be one of \(Self.batchMethods.sorted().joined(separator: ", "))")
            }
            let params = prepared(method, op["params"] ?? .object([:]))
            do {
                sizes.append(try await fitSize(method, params, pending: pending))
            } catch {
                throw Self.labelled(error, op: index, method)
            }
            if method == "object.create" { pending[index] = params }
        }
        var results: [JSONValue] = []
        try board.atomically {
            for (index, op) in ops.enumerated() {
                let method = op["method"]?.string ?? ""
                do {
                    let params = prepared(method, try resolve(op["params"] ?? .object([:]), results: results, index: index))
                    for id in [params["id"], params["near"]].compactMap({ $0?.string }) + (params["ids"]?.array?.compactMap(\.string) ?? []) where board.objects[id] == nil {
                        throw BoardError.notFound("object \(id) on board \(board.id)")
                    }
                    results.append(try dispatch(method, try fitted(method, params, size: sizes[index])))
                } catch {
                    throw Self.labelled(error, op: index, method)
                }
            }
        }
        return .object(["results": .array(results), "revision": .number(Double(board.revision))])
    }

    /// A batch op's failure, naming the op, with the code it would have had on its own.
    static func labelled(_ error: Error, op index: Int, _ method: String) -> Error {
        let prefix = "op \(index) (\(method)): "
        switch error {
        case let failure as Failure: return Failure(failure.code, prefix + failure.message)
        case BoardError.notFound(let message): return Failure("not_found", prefix + message)
        case BoardError.conflict(let message): return Failure("conflict", prefix + message)
        case BoardError.invalidParams(let message): return Failure("invalid_params", prefix + message)
        case ObjectMeasure.Failure.unsupported(let message): return Failure("unsupported", prefix + message)
        case ObjectMeasure.Failure.unavailable(let message): return Failure("unavailable", prefix + message)
        case ObjectMeasure.Failure.invalidParams(let message): return Failure("invalid_params", prefix + message)
        default: return Failure("invalid_params", prefix + String(describing: error))
        }
    }

    /// Replaces every string `"$n"` in `value` with the id op n created.
    private func resolve(_ value: JSONValue, results: [JSONValue], index: Int) throws -> JSONValue {
        switch value {
        case .string(let text):
            guard let n = Self.reference(text) else { return value }
            guard n < index, let id = results[n]["object"]?["id"] else { throw Failure("invalid_params", "\(text) must name an earlier create op") }
            return id
        case .array(let items): return .array(try items.map { try resolve($0, results: results, index: index) })
        case .object(let fields): return .object(try fields.mapValues { try resolve($0, results: results, index: index) })
        default: return value
        }
    }

    /// `layout.check`: accidental overlaps, arrows through tiles, and content that doesn't fit
    /// its frame, for `ids`, for what intersects `rect`, or for the whole board.
    private func check(_ p: JSONValue) async throws -> JSONValue {
        let board: Board
        var scope: Set<ObjectID>?
        if let ids = p["ids"]?.array?.compactMap(\.string) {
            guard let first = ids.first else { throw Failure("invalid_params", "ids must not be empty") }
            board = try self.board(forObject: first)
            for id in ids where board.objects[id] == nil { throw BoardError.notFound("object \(id) on this board") }
            scope = Set(ids)
        } else {
            board = try self.board(p)
            if let rect = try p["rect"].map({ try $0.decode(Frame.self) }) {
                let routes = board.routes()
                scope = Set(board.objects.values.filter { object in
                    if let path = routes[object.id] { return DrawingGeometry.path(path, crosses: rect.rect) || path.contains { rect.rect.contains($0) } }
                    return object.frame.intersects(rect)
                }.map(\.id))
            }
        }
        let report = board.layoutCheck(scope: scope)
        var overflow: [JSONValue] = []
        let measurable = board.objects.values
            .filter { scope?.contains($0.id) ?? true }
            .filter { $0.type == .code || $0.type == .note || ($0.type == .shape && ShapeSpec($0.props)?.kind == .text) }
            .sorted { $0.id < $1.id }
        for object in measurable {
            // Code wraps at its frame's width (so only its height overflows); notes and text wrap
            // there too.
            guard let size = try? await ObjectMeasure.size(type: object.type, props: object.props, width: object.frame.w, root: board.root),
                  let current = board.objects[object.id]?.frame else { continue }
            let x = max(0, size.width - current.w)
            let y = max(0, size.height - current.h)
            guard x >= 1 || y >= 1 else { continue }
            overflow.append(.object(["id": .string(object.id), "x": .number(x.rounded(.up)), "y": .number(y.rounded(.up))]))
        }
        return .object([
            "overlaps": .array(report.overlaps.map { .array($0.map(JSONValue.string)) }),
            "arrowCrossings": .array(report.crossings.map { .object(["arrow": .string($0.arrow), "crosses": .array($0.crosses.map(JSONValue.string))]) }),
            "overflow": .array(overflow),
        ])
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
        let encloses = board.enclosed(by: object).map(\.id)
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
        // Arrows drawn inside the object connect what it encloses: the structure a drawn box means.
        let arrows: [JSONValue] = board.arrows(enclosedBy: object).map { arrow, spec in
            .object(["arrow": .string(arrow.id), "from": spec.from.json, "to": spec.to.json,
                     "relation": spec.relation.map(JSONValue.string) ?? .null, "label": spec.label.map(JSONValue.string) ?? .null])
        }
        var graph: [String: JSONValue] = [
            "encloses": .array(encloses.map(JSONValue.string)),
            "enclosedBy": .array(enclosedBy.map(JSONValue.string)),
            "overlaps": .array(overlaps.map(JSONValue.string)),
            "arrowsOut": .array(arrowsOut),
            "arrowsIn": .array(arrowsIn),
            "arrows": .array(arrows),
        ]
        if let spec = ArrowSpec(object.props), object.type == .arrow {
            graph["from"] = spec.from.json
            graph["to"] = spec.to.json
        }
        return .object(graph)
    }
}
