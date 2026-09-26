import Foundation

/// One language server for a (language, project root): started on the first request, restarted
/// on the next request after a crash, documents synced from disk before every request.
public actor LanguageServer {
    public nonisolated let config: LanguageServerConfig
    public nonisolated let root: URL
    private let executable: URL
    private let environment: [String: String]
    private let live: LiveConnections

    private var connection: LSPConnection?
    private var starting: Task<LSPConnection, Error>?
    /// Bumped per launch and on stop, so a stale exit callback can't clobber a newer process.
    private var generation = 0
    /// Open documents: version sent last and a hash of the text it carried.
    private var documents: [URL: (version: Int, hash: Int)] = [:]
    private var inFlight = 0
    public private(set) var status: LanguageServerStatus = .stopped

    static let requestTimeout: Duration = .seconds(60)

    init(config: LanguageServerConfig, root: URL, executable: URL, environment: [String: String], live: LiveConnections) {
        self.config = config
        self.root = root
        self.executable = executable
        self.environment = environment
        self.live = live
    }

    var isBusy: Bool { inFlight > 0 || starting != nil }

    /// Background work the server reports (e.g. "Indexing"), which explains empty references.
    public var activity: [String] { connection?.activity ?? [] }

    // MARK: Requests

    public func hover(_ file: URL, at position: LSPPosition) async throws -> LSPHover? {
        let result = try await request("textDocument/hover", file) { uri in
            .object(["textDocument": .object(["uri": .string(uri)]), "position": position.json])
        }
        return LSPHover(result)
    }

    public func definition(_ file: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        LSPLocation.list(try await request("textDocument/definition", file) { uri in
            .object(["textDocument": .object(["uri": .string(uri)]), "position": position.json])
        })
    }

    public func references(_ file: URL, at position: LSPPosition, includeDeclaration: Bool) async throws -> [LSPLocation] {
        LSPLocation.list(try await request("textDocument/references", file) { uri in
            .object(["textDocument": .object(["uri": .string(uri)]), "position": position.json,
                     "context": .object(["includeDeclaration": .bool(includeDeclaration)])])
        })
    }

    public func documentSymbols(_ file: URL) async throws -> [LSPSymbol] {
        let result = try await request("textDocument/documentSymbol", file) { uri in
            .object(["textDocument": .object(["uri": .string(uri)])])
        }
        return (result.array ?? []).compactMap(LSPSymbol.init)
    }

    private func request(_ method: String, _ file: URL, _ params: (String) -> JSONValue) async throws -> JSONValue {
        inFlight += 1
        defer { inFlight -= 1 }
        let connection = try await connected()
        let uri = try sync(file, on: connection)
        return try await connection.request(method, params(uri), timeout: Self.requestTimeout)
    }

    /// Opens the file with its current disk content, or sends the whole new text when it changed
    /// since the server last saw it. Checked per request, so no file watching is needed.
    private func sync(_ file: URL, on connection: LSPConnection) throws -> String {
        let uri = file.absoluteString
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw LSPError.unreadable(file.path) }
        let hash = text.hashValue
        if let open = documents[file] {
            guard open.hash != hash else { return uri }
            let version = open.version + 1
            connection.notify("textDocument/didChange", .object([
                "textDocument": .object(["uri": .string(uri), "version": .number(Double(version))]),
                "contentChanges": .array([.object(["text": .string(text)])]),
            ]))
            documents[file] = (version, hash)
        } else {
            connection.notify("textDocument/didOpen", .object([
                "textDocument": .object(["uri": .string(uri), "languageId": .string(config.languageID(for: file) ?? config.language),
                                         "version": .number(1), "text": .string(text)]),
            ]))
            documents[file] = (1, hash)
        }
        return uri
    }

    // MARK: Lifecycle

    private func connected() async throws -> LSPConnection {
        if let connection { return connection }
        if let starting { return try await starting.value }
        status = .starting
        let task = Task { try await self.launch() }
        starting = task
        defer { starting = nil }
        do {
            return try await task.value
        } catch {
            status = .crashed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            throw error
        }
    }

    private func launch() async throws -> LSPConnection {
        generation += 1
        let launched = generation
        let connection = LSPConnection(executable: executable, arguments: config.arguments, environment: environment, directory: root) { [weak self] reason in
            Task { await self?.exited(launched, reason: reason) }
        }
        do {
            try connection.start()
        } catch {
            throw LSPError.startFailed("\(executable.path): \(error.localizedDescription)")
        }
        live.insert(connection)
        do {
            _ = try await connection.request("initialize", initializeParams, timeout: Self.requestTimeout)
        } catch {
            connection.kill()
            throw error
        }
        connection.notify("initialized", .object([:]))
        documents = [:]
        self.connection = connection
        status = .running(pid: connection.pid)
        return connection
    }

    private func exited(_ launched: Int, reason: String) {
        guard launched == generation else { return }
        if let connection { live.remove(connection) }
        connection = nil
        documents = [:]
        status = .crashed(reason)
    }

    /// LSP shutdown/exit, escalating to SIGTERM and SIGKILL for a server that won't leave.
    public func stop() async {
        generation += 1
        guard let connection else {
            status = .stopped
            return
        }
        self.connection = nil
        documents = [:]
        _ = try? await connection.request("shutdown", .null, timeout: .seconds(2))
        connection.notify("exit", nil)
        if await !connection.waitForExit(timeout: .seconds(2)) {
            connection.terminate()
            if await !connection.waitForExit(timeout: .seconds(2)) { connection.kill() }
        }
        live.remove(connection)
        status = .stopped
    }

    private var initializeParams: JSONValue {
        let rootURI = JSONValue.string(root.absoluteString)
        return .object([
            "processId": .number(Double(getpid())),
            "clientInfo": .object(["name": .string("Canvas")]),
            "rootUri": rootURI,
            "rootPath": .string(root.path),
            "workspaceFolders": .array([.object(["uri": rootURI, "name": .string(root.lastPathComponent)])]),
            "capabilities": .object([
                "general": .object(["positionEncodings": .array([.string("utf-16")])]),
                "window": .object(["workDoneProgress": .bool(true)]),
                "workspace": .object(["configuration": .bool(true), "workspaceFolders": .bool(true)]),
                "textDocument": .object([
                    "synchronization": .object(["dynamicRegistration": .bool(false), "didSave": .bool(false)]),
                    "hover": .object(["contentFormat": .array([.string("markdown"), .string("plaintext")])]),
                    "definition": .object(["linkSupport": .bool(true)]),
                    "references": .object([:]),
                    "documentSymbol": .object(["hierarchicalDocumentSymbolSupport": .bool(true)]),
                ]),
            ]),
        ])
    }
}

/// Every running server process, reachable synchronously so app quit can end them without
/// awaiting actors.
final class LiveConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: LSPConnection] = [:]

    func insert(_ connection: LSPConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
    }

    func remove(_ connection: LSPConnection) {
        lock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    func terminateAll() {
        for connection in lock.withLock({ Array(connections.values) }) {
            connection.notify("exit", nil)
            connection.terminate()
        }
    }
}
