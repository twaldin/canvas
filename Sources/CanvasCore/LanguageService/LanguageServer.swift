import Darwin
import Foundation

/// One language server for a (language, project root): started on the first request, restarted
/// on the next request after a crash.
///
/// Documents are client-owned only while needed: for the duration of a request, or while a
/// code view pins them (`pin`/`unpin`). Every request first re-syncs each open document whose
/// file changed on disk, so the server never answers from stale client-supplied text.
public actor LanguageServer {
    public nonisolated let config: LanguageServerConfig
    public nonisolated let root: URL
    private let executable: URL
    private let environment: [String: String]
    private let live: LiveConnections

    /// The initialized process.
    private var connection: LSPConnection?
    /// The process between spawn and a successful initialize; `stop()` must reach it too.
    private var launching: LSPConnection?
    private var starting: Task<LSPConnection, Error>?
    /// Bumped per launch and on stop: a launch or exit from an older generation is discarded.
    private var generation = 0
    private var documents: [URL: Document] = [:]
    private var pinned: Set<URL>
    private var inFlight = 0
    /// What the running server said it can answer (`initialize` result `capabilities`).
    private var capabilities: JSONValue = .object([:])
    public private(set) var status: LanguageServerStatus = .stopped

    static let requestTimeout: Duration = .seconds(60)

    private struct Document {
        var version: Int
        var stamp: FileStamp
        var hash: Int
        /// Requests currently relying on the document being open.
        var users: Int
    }

    init(config: LanguageServerConfig, root: URL, executable: URL, environment: [String: String], live: LiveConnections, pinned: Set<URL> = []) {
        self.config = config
        self.root = root
        self.executable = executable
        self.environment = environment
        self.live = live
        self.pinned = pinned
    }

    var isBusy: Bool { inFlight > 0 || starting != nil }

    /// The server process, while starting or running.
    public var pid: Int32? { (connection ?? launching)?.pid }

    /// Documents the server currently holds as client-owned.
    public var openDocumentCount: Int { documents.count }

    /// Background work the server reports (e.g. "Indexing"), which explains empty answers.
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

    /// References including the declaration.
    public func references(_ file: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        LSPLocation.list(try await request("textDocument/references", file) { uri in
            .object(["textDocument": .object(["uri": .string(uri)]), "position": position.json,
                     "context": .object(["includeDeclaration": .bool(true)])])
        })
    }

    /// Where the type of the value at `position` is declared.
    public func typeDefinition(_ file: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        try await require("typeDefinitionProvider", "type definitions")
        return LSPLocation.list(try await request("textDocument/typeDefinition", file) { uri in
            .object(["textDocument": .object(["uri": .string(uri)]), "position": position.json])
        })
    }

    /// The callable declared at `position` (its name), as the server's call hierarchy knows it:
    /// empty when nothing callable is there.
    public func prepareCallHierarchy(_ file: URL, at position: LSPPosition) async throws -> [LSPCallHierarchyItem] {
        try await require("callHierarchyProvider", "call hierarchy")
        let result = try await request("textDocument/prepareCallHierarchy", file) { uri in
            .object(["textDocument": .object(["uri": .string(uri)]), "position": position.json])
        }
        return (result.array ?? []).compactMap(LSPCallHierarchyItem.init)
    }

    /// What calls `item`, each caller with the ranges of its calls (in the caller's file).
    public func incomingCalls(_ item: LSPCallHierarchyItem) async throws -> [LSPCallHierarchyCall] {
        try await require("callHierarchyProvider", "call hierarchy")
        let result = try await request("callHierarchy/incomingCalls", item.url) { _ in .object(["item": item.json]) }
        return (result.array ?? []).compactMap { LSPCallHierarchyCall($0, end: "from") }
    }

    /// What `item` calls, each callee with the ranges of the calls (in `item`'s file).
    public func outgoingCalls(_ item: LSPCallHierarchyItem) async throws -> [LSPCallHierarchyCall] {
        try await require("callHierarchyProvider", "call hierarchy")
        let result = try await request("callHierarchy/outgoingCalls", item.url) { _ in .object(["item": item.json]) }
        return (result.array ?? []).compactMap { LSPCallHierarchyCall($0, end: "to") }
    }

    /// Starts the server if needed and throws `unsupportedRequest` unless its capabilities list
    /// `provider` (present and not false).
    private func require(_ provider: String, _ what: String) async throws {
        _ = try await connected()
        switch capabilities[provider] {
        case nil, .null?, .bool(false)?: throw LSPError.unsupportedRequest("\(config.command) does not answer \(what) requests (no \(provider) in its capabilities)")
        default: return
        }
    }

    public func documentSymbols(_ file: URL) async throws -> [LSPSymbol] {
        let result = try await request("textDocument/documentSymbol", file) { uri in
            .object(["textDocument": .object(["uri": .string(uri)])])
        }
        return (result.array ?? []).compactMap(LSPSymbol.init)
    }

    /// Symbols matching `query` anywhere in the server's project (`workspace/symbol`).
    /// `file`, one of the project's, is open for the request: tsserver answers only for the
    /// projects of open files ("No Project" otherwise).
    public func workspaceSymbols(_ query: String, opening file: URL) async throws -> [LSPWorkspaceSymbol] {
        let result = try await request("workspace/symbol", file) { _ in .object(["query": .string(query)]) }
        return (result.array ?? []).compactMap(LSPWorkspaceSymbol.init)
    }

    private func request(_ method: String, _ file: URL, _ params: (String) -> JSONValue) async throws -> JSONValue {
        inFlight += 1
        defer { inFlight -= 1 }
        let connection = try await connected()
        await refreshOpenDocuments(on: connection)
        let uri = try await open(file, on: connection)
        defer { release(file, on: connection) }
        return try await connection.request(method, params(uri), timeout: Self.requestTimeout)
    }

    // MARK: Documents

    /// Keeps `file` open between requests (a code view shows it).
    func pin(_ file: URL) {
        pinned.insert(file)
    }

    func unpin(_ file: URL) {
        pinned.remove(file)
        if let connection, documents[file]?.users == 0 { close(file, on: connection) }
    }

    /// Opens `file` for one request (or counts another user of an open document). Disk reads
    /// run on GCD; the actor may interleave other requests meanwhile, so state is re-checked after.
    private func open(_ file: URL, on connection: LSPConnection) async throws -> String {
        let uri = file.absoluteString
        if documents[file] == nil {
            guard let (stamp, text) = await offPool({ FileStamp.read(file) }) else { throw LSPError.unreadable(file.path) }
            guard connection === self.connection else { throw LSPError.serverExited("\(config.command) restarted") }
            if documents[file] == nil {
                connection.notify("textDocument/didOpen", .object([
                    "textDocument": .object(["uri": .string(uri), "languageId": .string(config.languageID(for: file) ?? config.language),
                                             "version": .number(1), "text": .string(text)]),
                ]))
                documents[file] = Document(version: 1, stamp: stamp, hash: text.hashValue, users: 1)
                return uri
            }
        }
        documents[file]?.users += 1
        return uri
    }

    private func release(_ file: URL, on connection: LSPConnection) {
        guard connection === self.connection, documents[file] != nil else { return }
        documents[file]?.users -= 1
        if documents[file]?.users == 0, !pinned.contains(file) { close(file, on: connection) }
    }

    private func close(_ file: URL, on connection: LSPConnection) {
        guard documents.removeValue(forKey: file) != nil else { return }
        connection.notify("textDocument/didClose", .object(["textDocument": .object(["uri": .string(file.absoluteString)])]))
    }

    /// Sends the new text of every open document whose file changed on disk (a stat per open
    /// document on GCD; files are read only when their stamp moved), and closes deleted ones.
    private func refreshOpenDocuments(on connection: LSPConnection) async {
        let known = documents.mapValues(\.stamp)
        guard !known.isEmpty else { return }
        let current = await offPool { () -> [URL: FileStamp.Read] in
            var result: [URL: FileStamp.Read] = [:]
            for (file, stamp) in known {
                guard let now = FileStamp(file) else {
                    result[file] = .gone
                    continue
                }
                guard now != stamp else { continue }
                result[file] = FileStamp.read(file).map { .changed($0.stamp, $0.text) } ?? .gone
            }
            return result
        }
        guard connection === self.connection else { return }
        for (file, read) in current {
            guard let document = documents[file] else { continue }
            switch read {
            case .gone:
                if document.users == 0 { close(file, on: connection) }
            case .changed(let stamp, let text):
                documents[file]?.stamp = stamp
                let hash = text.hashValue
                guard hash != document.hash else { continue }
                let version = document.version + 1
                connection.notify("textDocument/didChange", .object([
                    "textDocument": .object(["uri": .string(file.absoluteString), "version": .number(Double(version))]),
                    "contentChanges": .array([.object(["text": .string(text)])]),
                ]))
                documents[file]?.version = version
                documents[file]?.hash = hash
            }
        }
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
            // A stop while starting already set .stopped; anything else is a failed start.
            if status == .starting { status = .crashed((error as? LocalizedError)?.errorDescription ?? "\(error)") }
            throw error
        }
    }

    private func launch() async throws -> LSPConnection {
        generation += 1
        let launched = generation
        let connection = LSPConnection(executable: executable, arguments: config.arguments, environment: environment, directory: root) { [weak self] connection, reason in
            Task { await self?.exited(connection, generation: launched, reason: reason) }
        }
        do {
            try connection.start()
        } catch {
            throw LSPError.startFailed("\(executable.path): \(error.localizedDescription)")
        }
        live.insert(connection)
        launching = connection
        defer { if launching === connection { launching = nil } }
        let initialized: JSONValue
        do {
            initialized = try await connection.request("initialize", initializeParams, timeout: Self.requestTimeout)
        } catch {
            live.remove(connection)
            connection.kill()
            throw error
        }
        // stop() ran during initialize and already terminated this process; never publish it.
        guard launched == generation else {
            live.remove(connection)
            connection.kill()
            throw LSPError.serverExited("\(config.command) was stopped while starting")
        }
        connection.notify("initialized", .object([:]))
        documents = [:]
        capabilities = initialized["capabilities"] ?? .object([:])
        self.connection = connection
        status = .running(pid: connection.pid)
        return connection
    }

    private func exited(_ exited: LSPConnection, generation launched: Int, reason: String) {
        live.remove(exited)
        guard launched == generation, exited === connection else { return }
        connection = nil
        documents = [:]
        status = .crashed(reason)
    }

    /// LSP shutdown/exit for a running server, SIGTERM for one still starting, escalating to
    /// SIGKILL for either that won't leave.
    public func stop() async {
        generation += 1
        status = .stopped
        let running = connection
        let starting = launching
        connection = nil
        launching = nil
        documents = [:]
        if let starting {
            await starting.terminate(grace: .seconds(1))
            live.remove(starting)
        }
        if let running {
            _ = try? await running.request("shutdown", .null, timeout: .seconds(2))
            running.notify("exit", nil)
            if await !running.waitForExit(timeout: .seconds(2)) { await running.terminate(grace: .seconds(2)) }
            live.remove(running)
        }
    }

    private var initializeParams: JSONValue {
        let rootURI = JSONValue.string(root.absoluteString)
        var params: [String: JSONValue] = [
            "processId": .number(Double(getpid())),
            "clientInfo": .object(["name": .string("easl")]),
            "rootUri": rootURI,
            "rootPath": .string(root.path),
            "workspaceFolders": .array([.object(["uri": rootURI, "name": .string(root.lastPathComponent)])]),
            "capabilities": .object([
                "general": .object(["positionEncodings": .array([.string("utf-16")])]),
                "window": .object(["workDoneProgress": .bool(true)]),
                "workspace": .object(["configuration": .bool(true), "workspaceFolders": .bool(true), "symbol": .object([:])]),
                "textDocument": .object([
                    "synchronization": .object(["dynamicRegistration": .bool(false), "didSave": .bool(false)]),
                    "hover": .object(["contentFormat": .array([.string("markdown"), .string("plaintext")])]),
                    "definition": .object(["linkSupport": .bool(true)]),
                    "references": .object([:]),
                    "documentSymbol": .object(["hierarchicalDocumentSymbolSupport": .bool(true)]),
                    "typeDefinition": .object(["linkSupport": .bool(true)]),
                    "callHierarchy": .object(["dynamicRegistration": .bool(false)]),
                ]),
            ]),
        ]
        if let options = config.initializationOptions { params["initializationOptions"] = options }
        return .object(params)
    }
}

/// Identity and version of a file on disk: rename-over (new inode), size, or mtime changes.
struct FileStamp: Equatable, @unchecked Sendable {
    enum Read: Sendable {
        case gone
        case changed(FileStamp, String)
    }

    let inode: UInt64
    let size: Int64
    let modified: timespec

    init?(_ file: URL) {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return nil }
        inode = info.st_ino
        size = info.st_size
        modified = info.st_mtimespec
    }

    /// Stamp and UTF-8 text, or nil when unreadable. Blocking: call through `offPool`.
    static func read(_ file: URL) -> (stamp: FileStamp, text: String)? {
        guard let stamp = FileStamp(file), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return (stamp, text)
    }

    static func == (lhs: FileStamp, rhs: FileStamp) -> Bool {
        lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
    }
}

/// Every server process that has been spawned and not yet reaped, reachable without the actors
/// so app quit can end them.
final class LiveConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: LSPConnection] = [:]

    var count: Int { lock.withLock { connections.count } }

    func insert(_ connection: LSPConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
    }

    func remove(_ connection: LSPConnection) {
        lock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    /// Asks every server to exit, SIGTERMs it, and SIGKILLs whatever is left after `grace`.
    func terminateAll(grace: Duration) async {
        let all = lock.withLock { Array(connections.values) }
        await withTaskGroup(of: Void.self) { group in
            for connection in all {
                group.addTask {
                    connection.notify("exit", nil)
                    await connection.terminate(grace: grace)
                    self.remove(connection)
                }
            }
        }
    }
}
