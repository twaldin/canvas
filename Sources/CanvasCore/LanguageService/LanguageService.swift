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
        let (server, file) = try server(for: file, boardRoot: boardRoot)
        return try await server.hover(file, at: position)
    }

    public func definition(file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        let (server, file) = try server(for: file, boardRoot: boardRoot)
        return try await server.definition(file, at: position)
    }

    public func references(file: URL, boardRoot: URL, at position: LSPPosition, includeDeclaration: Bool = true) async throws -> [LSPLocation] {
        let (server, file) = try server(for: file, boardRoot: boardRoot)
        return try await server.references(file, at: position, includeDeclaration: includeDeclaration)
    }

    public func documentSymbols(file: URL, boardRoot: URL) async throws -> [LSPSymbol] {
        let (server, file) = try server(for: file, boardRoot: boardRoot)
        return try await server.documentSymbols(file)
    }

    /// The server that would answer for `file`, if one exists (running, crashed, or starting).
    public func existingServer(for file: URL, boardRoot: URL) -> LanguageServer? {
        guard let (config, file) = config(for: file) else { return nil }
        return servers[Key(language: config.language, root: config.projectRoot(for: file, within: boardRoot.resolvingSymlinksInPath()))]
    }

    /// The source line of each location (trimmed), reading every file once, for reference lists.
    public func lineTexts(_ locations: [LSPLocation]) -> [String] {
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

    // MARK: Registry

    private func config(for file: URL) -> (LanguageServerConfig, URL)? {
        let file = file.resolvingSymlinksInPath()
        return configs.first { $0.languageID(for: file) != nil }.map { ($0, file) }
    }

    private func server(for file: URL, boardRoot: URL) throws -> (LanguageServer, URL) {
        guard let (config, file) = config(for: file) else {
            throw LSPError.unsupportedLanguage(file.pathExtension.isEmpty ? file.lastPathComponent : ".\(file.pathExtension) files")
        }
        let key = Key(language: config.language, root: config.projectRoot(for: file, within: boardRoot.resolvingSymlinksInPath()))
        let server: LanguageServer
        if let existing = servers[key] {
            server = existing
        } else {
            guard let executable = shell.resolve(config.command) else {
                throw LSPError.unavailable("\(config.command) is not installed (not found on the login shell's PATH)")
            }
            if servers.count >= maxRunning, let oldest = lastUse.min(by: { $0.value < $1.value })?.key {
                retire(oldest)
            }
            server = LanguageServer(config: config, root: key.root, executable: executable, environment: shell.environment, live: live)
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
        if await server.isBusy, idleTimers[key]?.token == token {
            return touch(key)
        }
        guard idleTimers[key]?.token == token else { return }
        idleTimers[key] = nil
        retire(key)
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

    /// App quit: no time to await actors; tell every server to exit and signal it.
    public nonisolated func terminateAll() {
        live.terminateAll()
    }
}
