import Foundation

/// The app's language servers: one per (language, project root), shared by every tile. Servers
/// start on their first request, shut down after `idleTimeout` without requests, and at most
/// `maxRunning` exist at once (the least recently used one is stopped to make room).
public actor LanguageService {
    struct Key: Hashable {
        let language: String
        let root: URL
    }

    private let configs: [LanguageServerConfig]
    private let shell: LoginShell
    private let idleTimeout: Duration
    private let maxRunning: Int
    private let live = LiveConnections()

    private var servers: [Key: LanguageServer] = [:]
    private var lastUse: [Key: Int] = [:]
    private var uses = 0
    private var idleTimers: [Key: (token: Int, task: Task<Void, Never>)] = [:]
    /// Files code views show, with how many views retain each (see `retain`).
    private var retained: [URL: Int] = [:]

    public init(configs: [LanguageServerConfig] = LanguageServerConfig.defaults, idleTimeout: Duration = .seconds(300),
                maxRunning: Int = 4, shell: LoginShell = .shared) {
        self.configs = configs
        self.idleTimeout = idleTimeout
        self.maxRunning = max(1, maxRunning)
        self.shell = shell
    }

    // MARK: Requests
    //
    // `file` is absolute; `boardRoot` bounds the search for the project root. Positions and
    // results use LSP's zero-based lines and UTF-16 columns.

    public func hover(file: URL, boardRoot: URL, at position: LSPPosition) async throws -> LSPHover? {
        let (server, file) = try await server(for: file, boardRoot: boardRoot)
        return try await server.hover(file, at: position)
    }

    public func definition(file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        let (server, file) = try await server(for: file, boardRoot: boardRoot)
        return try await server.definition(file, at: position)
    }

    public func references(file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        let (server, file) = try await server(for: file, boardRoot: boardRoot)
        return try await server.references(file, at: position)
    }

    public func documentSymbols(file: URL, boardRoot: URL) async throws -> [LSPSymbol] {
        let (server, file) = try await server(for: file, boardRoot: boardRoot)
        return try await server.documentSymbols(file)
    }

    public func typeDefinition(file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        let (server, file) = try await server(for: file, boardRoot: boardRoot)
        return try await server.typeDefinition(file, at: position)
    }

    public func prepareCallHierarchy(file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPCallHierarchyItem] {
        let (server, file) = try await server(for: file, boardRoot: boardRoot)
        return try await server.prepareCallHierarchy(file, at: position)
    }

    /// Asked of the server of the item's file, which is the server that named it.
    public func incomingCalls(_ item: LSPCallHierarchyItem, boardRoot: URL) async throws -> [LSPCallHierarchyCall] {
        let (server, _) = try await server(for: item.url, boardRoot: boardRoot)
        return try await server.incomingCalls(item)
    }

    public func outgoingCalls(_ item: LSPCallHierarchyItem, boardRoot: URL) async throws -> [LSPCallHierarchyCall] {
        let (server, _) = try await server(for: item.url, boardRoot: boardRoot)
        return try await server.outgoingCalls(item)
    }

    /// Workspace symbols matching `query` from the server of each project `files` fall in (one
    /// request per language and project root, started if needed), in the servers' order. A
    /// project whose server is missing or fails adds nothing; only when every one failed is the
    /// first error thrown.
    public func workspaceSymbols(_ query: String, files: [URL], boardRoot: URL) async throws -> [LSPWorkspaceSymbol] {
        var seen: Set<Key> = []
        var projects: [URL] = []
        for file in files {
            guard let key = key(for: file, boardRoot: boardRoot), seen.insert(key).inserted else { continue }
            projects.append(file)
        }
        var symbols: [LSPWorkspaceSymbol] = []
        var failure: Error?
        var answered = false
        for file in projects {
            do {
                let (server, _) = try await server(for: file, boardRoot: boardRoot)
                symbols += try await server.workspaceSymbols(query)
                answered = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = failure ?? error
            }
        }
        if !answered, let failure { throw failure }
        return symbols
    }

    /// The server that would answer for `file`, if one exists (running, crashed, or starting).
    public func existingServer(for file: URL, boardRoot: URL) -> LanguageServer? {
        key(for: file, boardRoot: boardRoot).flatMap { servers[$0] }
    }

    /// A code view shows `file`: keep it open in its server between requests (re-synced from
    /// disk before each one) until every view that retained it releases it.
    public func retain(file: URL, boardRoot: URL) async {
        let file = GitDiffEngine.realPath(file)
        retained[file, default: 0] += 1
        guard retained[file] == 1, let server = existingServer(for: file, boardRoot: boardRoot) else { return }
        await server.pin(file)
    }

    public func release(file: URL, boardRoot: URL) async {
        let file = GitDiffEngine.realPath(file)
        guard let count = retained[file] else { return }
        guard count <= 1 else {
            retained[file] = count - 1
            return
        }
        retained[file] = nil
        await existingServer(for: file, boardRoot: boardRoot)?.unpin(file)
    }

    /// The source line of each location (trimmed), reading every file once (on GCD), for
    /// reference lists.
    public nonisolated func lineTexts(_ locations: [LSPLocation]) async -> [String] {
        await offPool {
            var lines: [URL: [Substring]] = [:]
            return locations.map { location in
                if lines[location.url] == nil {
                    let text = (try? String(contentsOf: location.url, encoding: .utf8)) ?? ""
                    lines[location.url] = text.split(separator: "\n", omittingEmptySubsequences: false)
                }
                let fileLines = lines[location.url] ?? []
                let index = location.range.start.line
                return fileLines.indices.contains(index) ? fileLines[index].trimmingCharacters(in: .whitespaces) : ""
            }
        }
    }

    // MARK: Registry

    private func config(for file: URL) -> (LanguageServerConfig, URL)? {
        let file = GitDiffEngine.realPath(file)
        return configs.first { $0.languageID(for: file) != nil }.map { ($0, file) }
    }

    private func key(for file: URL, boardRoot: URL) -> Key? {
        guard let (config, file) = config(for: file) else { return nil }
        return Key(language: config.language, root: config.projectRoot(for: file, within: GitDiffEngine.realPath(boardRoot)))
    }

    private func server(for file: URL, boardRoot: URL) async throws -> (LanguageServer, URL) {
        guard let (config, file) = config(for: file), let key = key(for: file, boardRoot: boardRoot) else {
            throw LSPError.unsupportedLanguage(file.pathExtension.isEmpty ? file.lastPathComponent : ".\(file.pathExtension) files")
        }
        let server: LanguageServer
        if let existing = servers[key] {
            server = existing
        } else {
            // The login shell is a blocking subprocess (once per server, then cached).
            let shell = shell
            let (found, environment) = await offPool { (shell.locate(config), shell.environment) }
            guard let executable = found else { throw LSPError.unavailable(config.notFound) }
            // Another request may have created the server while the shell ran.
            if let existing = servers[key] {
                touch(key)
                return (existing, file)
            }
            if servers.count >= maxRunning, let oldest = lastUse.min(by: { $0.value < $1.value })?.key {
                retire(oldest)
            }
            let pinned = Set(retained.keys.filter { self.key(for: $0, boardRoot: boardRoot) == key })
            server = LanguageServer(config: config, root: key.root, executable: executable, environment: environment, live: live, pinned: pinned)
            servers[key] = server
        }
        touch(key)
        return (server, file)
    }

    private func touch(_ key: Key) {
        uses += 1
        lastUse[key] = uses
        idleTimers[key]?.task.cancel()
        let token = uses
        let timeout = idleTimeout
        idleTimers[key] = (token, Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.expire(key, token: token)
        })
    }

    private func expire(_ key: Key, token: Int) async {
        guard idleTimers[key]?.token == token, let server = servers[key] else { return }
        // A request still waiting (a slow first index, say) counts as use.
        let busy = await server.isBusy
        guard idleTimers[key]?.token == token else { return }
        if busy { touch(key) } else { retire(key) }
    }

    /// Removes a server from the registry synchronously (so no request can reach it) and stops it.
    private func retire(_ key: Key) {
        guard let server = servers.removeValue(forKey: key) else { return }
        lastUse[key] = nil
        idleTimers.removeValue(forKey: key)?.task.cancel()
        Task { await server.stop() }
    }

    /// Graceful shutdown of every server.
    public func stopAll() async {
        let all = Array(servers.values)
        servers = [:]
        lastUse = [:]
        for timer in idleTimers.values { timer.task.cancel() }
        idleTimers = [:]
        await withTaskGroup(of: Void.self) { group in
            for server in all { group.addTask { await server.stop() } }
        }
    }

    /// Server processes spawned and not yet reaped.
    public nonisolated var liveProcessCount: Int { live.count }

    /// App quit: tells every server process to exit, SIGTERMs it, and SIGKILLs any still alive
    /// after `grace`; returns once they're reaped. Needs no actor, so it can't queue behind a
    /// busy registry.
    public nonisolated func terminateAll(grace: Duration = .seconds(2)) async {
        await live.terminateAll(grace: grace)
    }
}
