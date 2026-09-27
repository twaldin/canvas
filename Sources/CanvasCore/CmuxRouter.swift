import Foundation

/// The cmux-compatible socket subset (docs/contracts.md): enough of cmux's v2 browser API for
/// omp's native `browser` tool to drive browser tiles. Surfaces are object ids — a terminal
/// tile is the calling surface, a browser tile is a browser surface — and workspaces are boards.
/// Page work runs in the app's WebKit layer through `perform`.
@MainActor
public final class CmuxRouter {
    public let registry: BoardRegistry
    /// When set, every connection must send `auth <password>` before any request.
    public let password: String?
    /// Runs a validated command in a browser tile; the result gains `surface_id`. The last
    /// argument is the terminal driving it (`driver(of:on:connection:)`), nil when unknown.
    public var perform: (@MainActor (Board, CanvasObject, CmuxBrowserCommand, ObjectID?) async throws -> JSONValue)?

    public init(registry: BoardRegistry, password: String? = nil) {
        self.registry = registry
        self.password = password
    }

    /// Entry point for a SocketServer started with `acceptsTextLines`: JSON requests, plus the
    /// plain-text `auth` line cmux clients send first when CMUX_SOCKET_PASSWORD is set.
    public func handle(_ request: JSONValue, connection: SocketServer.Connection) async -> JSONValue? {
        if case .string(let line) = request {
            connection.send(line: textReply(line, connection: connection))
            return nil
        }
        let id = request["id"] ?? .null
        do {
            guard let method = request["method"]?.string else { throw CmuxError.invalidParams("missing method") }
            guard password == nil || connection.authenticated else {
                throw CmuxError("unauthorized", "send `auth <password>` first")
            }
            let params = request["params"] ?? .object([:])
            guard params.object != nil else { throw CmuxError.invalidParams("params must be an object") }
            return ok(id, try await dispatch(method, params, connection: connection))
        } catch let error as CmuxError {
            return failure(id, error)
        } catch let error as BoardError {
            switch error {
            case .notFound(let message): return failure(id, CmuxError("not_found", message))
            case .conflict(let message): return failure(id, CmuxError("conflict", message))
            case .invalidParams(let message): return failure(id, .invalidParams(message))
            }
        } catch {
            return failure(id, CmuxError("internal_error", String(describing: error)))
        }
    }

    private func textReply(_ line: String, connection: SocketServer.Connection) -> String {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.first == "auth" else { return "ERROR: Unknown command '\(parts.first ?? "")'" }
        guard let password else {
            connection.authenticated = true
            return "OK: No password required"
        }
        guard parts.count == 2, String(parts[1]) == password else { return "ERROR: Invalid password" }
        connection.authenticated = true
        return "OK: Authenticated"
    }

    private func ok(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["id": id, "ok": .bool(true), "result": result])
    }

    private func failure(_ id: JSONValue, _ error: CmuxError) -> JSONValue {
        .object(["id": id, "ok": .bool(false), "error": .object(["code": .string(error.code), "message": .string(error.message)])])
    }

    private func dispatch(_ method: String, _ params: JSONValue, connection: SocketServer.Connection) async throws -> JSONValue {
        switch method {
        case "browser.open_split": return try openSplit(params, connection: connection)
        case "surface.list": return try list(params)
        case "surface.close":
            let (board, browser) = try browserSurface(params)
            try board.delete(browser.id, caller: driver(of: browser, on: board, connection: connection))
            return .object(["surface_id": .string(browser.id), "workspace_id": .string(board.id)])
        default:
            guard let command = try CmuxBrowserCommand.parse(method: method, params: params) else {
                throw CmuxError("method_not_found", "\(method) is not part of the cmux subset this socket serves")
            }
            let (board, browser) = try browserSurface(params)
            guard let perform else { throw CmuxError("unavailable", "browser tiles are not available") }
            var result = try await perform(board, browser, command, driver(of: browser, on: board, connection: connection)).object ?? [:]
            result["surface_id"] = .string(browser.id)
            return .object(result)
        }
    }

    /// The terminal a command on `browser` comes from. omp sends only the browser's id: the
    /// terminal this connection opened splits from, else the terminal that opened the tile
    /// (omp drives and closes the surfaces it opened).
    private func driver(of browser: CanvasObject, on board: Board, connection: SocketServer.Connection) -> ObjectID? {
        let opener: ObjectID? = if case .agent(let tile) = browser.createdBy { tile } else { nil }
        return connection.caller.flatMap { board.objects[$0] != nil ? $0 : nil } ?? opener
    }

    /// A new browser tile beside the calling terminal (`surface_id`), else in the viewport of
    /// the workspace board (`workspace_id`) or the frontmost board.
    private func openSplit(_ params: JSONValue, connection: SocketServer.Connection) throws -> JSONValue {
        let callerID = try CmuxBrowserCommand.optional(params, "surface_id", \.string)
        let workspace = try CmuxBrowserCommand.optional(params, "workspace_id", \.string)
        let caller = callerID.flatMap { id in registry.board(containing: id).map { ($0, $0.objects[id]!) } }
        guard let board = caller?.0 ?? workspace.flatMap({ registry.boards[$0] }) ?? registry.frontmost.flatMap({ registry.boards[$0] }) else {
            throw CmuxError("not_found", "no open canvas for this surface or workspace")
        }
        let raw = try CmuxBrowserCommand.optional(params, "url", \.string) ?? "about:blank"
        guard let url = BrowserURL.normalize(raw) else { throw CmuxError.invalidParams("not a URL: \(raw)") }
        let anchor = caller.flatMap { $0.1.type == .terminal ? $0.1.id : nil }
        let browser = board.create(type: .browser, props: .object(["url": .string(url.absoluteString)]), caller: anchor)
        if let anchor { connection.caller = anchor }
        return .object([
            "surface_id": .string(browser.id),
            "workspace_id": .string(board.id),
            "url": .string(url.absoluteString),
            "created_split": .bool(true),
            "placement_strategy": .string(anchor == nil ? "viewport" : "beside_caller"),
        ])
    }

    /// Terminal and browser tiles of one board. `surface_id` picks the board containing it.
    private func list(_ params: JSONValue) throws -> JSONValue {
        let board: Board
        if let id = try CmuxBrowserCommand.optional(params, "surface_id", \.string) {
            guard let owner = registry.board(containing: id) else { throw CmuxError("not_found", "surface \(id) not found") }
            board = owner
        } else if let workspace = try CmuxBrowserCommand.optional(params, "workspace_id", \.string) {
            guard let owner = registry.boards[workspace] else { throw CmuxError("not_found", "workspace \(workspace) not found") }
            board = owner
        } else {
            guard let front = registry.frontmost.flatMap({ registry.boards[$0] }) else { throw CmuxError("not_found", "no open canvas") }
            board = front
        }
        let surfaces = board.objects.values
            .filter { $0.type == .terminal || $0.type == .browser }
            .sorted { $0.z < $1.z }
            .map { object -> JSONValue in
                var row: [String: JSONValue] = ["id": .string(object.id), "type": .string(object.type.rawValue)]
                // cmux's title is the page's own; the agent's `title` only names the tile.
                if let title = (object.props["pageTitle"] ?? object.props["title"])?.string { row["title"] = .string(title) }
                if object.type == .browser, let url = object.props["url"]?.string { row["url"] = .string(url) }
                return .object(row)
            }
        return .object(["workspace_id": .string(board.id), "window_id": .null, "surfaces": .array(surfaces)])
    }

    private func browserSurface(_ params: JSONValue) throws -> (Board, CanvasObject) {
        let id = try CmuxBrowserCommand.string(params, "surface_id")
        guard let board = registry.board(containing: id), let object = board.objects[id] else {
            throw CmuxError("not_found", "surface \(id) not found")
        }
        guard object.type == .browser else {
            throw CmuxError.invalidParams("surface \(id) is a \(object.type.rawValue) tile, not a browser")
        }
        return (board, object)
    }
}
