import Foundation

/// How to run one language's server and which files and project roots belong to it.
public struct LanguageServerConfig: Sendable, Equatable {
    /// Registry key, e.g. "swift".
    public var language: String
    /// Binary name looked up on the login PATH, or an absolute path.
    public var command: String
    public var arguments: [String]
    /// File extension (lowercased, no dot) → LSP languageId.
    public var languageIDs: [String: String]
    /// Files that mark a project root; the nearest one above a file (within the board root) wins.
    public var rootMarkers: [String]
    public var initializationOptions: JSONValue?
    /// Shown with an empty definition/references answer: why the server may not know yet.
    public var emptyResultHint: String?
    /// How to install the server, shown when its binary isn't on the login PATH.
    public var installHint: String?

    public init(language: String, command: String, arguments: [String] = [], languageIDs: [String: String], rootMarkers: [String],
                initializationOptions: JSONValue? = nil, emptyResultHint: String? = nil, installHint: String? = nil) {
        self.language = language
        self.command = command
        self.arguments = arguments
        self.languageIDs = languageIDs
        self.rootMarkers = rootMarkers
        self.initializationOptions = initializationOptions
        self.emptyResultHint = emptyResultHint
        self.installHint = installHint
    }

    public static let defaults: [LanguageServerConfig] = [
        // Background indexing would run `swift build` into the user's repo whenever a code tile
        // opens a Swift file; on a shared machine the index comes from the user's own builds.
        LanguageServerConfig(language: "swift", command: "sourcekit-lsp", languageIDs: ["swift": "swift"],
                             rootMarkers: ["Package.swift", "compile_commands.json", "buildServer.json"],
                             initializationOptions: .object(["backgroundIndexing": .bool(false)]),
                             emptyResultHint: "Canvas doesn't index Swift projects itself; sourcekit-lsp answers from the index your own builds write (swift build).",
                             installHint: "It comes with Xcode or the Command Line Tools: xcode-select --install"),
        LanguageServerConfig(language: "python", command: "pyright-langserver", arguments: ["--stdio"], languageIDs: ["py": "python", "pyi": "python"],
                             rootMarkers: ["pyrightconfig.json", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"],
                             installHint: "Install it with: npm install -g pyright"),
        LanguageServerConfig(language: "typescript", command: "typescript-language-server", arguments: ["--stdio"],
                             languageIDs: ["ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
                                           "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascriptreact"],
                             rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json"],
                             installHint: "Install it with: npm install -g typescript-language-server typescript@5 (TypeScript 7 has no tsserver, which the server needs)"),
        LanguageServerConfig(language: "go", command: "gopls", languageIDs: ["go": "go"], rootMarkers: ["go.work", "go.mod"],
                             installHint: "Install it with: go install golang.org/x/tools/gopls@latest"),
        LanguageServerConfig(language: "rust", command: "rust-analyzer", languageIDs: ["rs": "rust"], rootMarkers: ["Cargo.toml"],
                             installHint: "Install it with: rustup component add rust-analyzer"),
    ]

    public func languageID(for file: URL) -> String? {
        languageIDs[file.pathExtension.lowercased()]
    }

    /// Nearest directory containing a root marker, walking up from the file but never above
    /// `boundary` (the board root); the boundary itself when nothing marks a project.
    public func projectRoot(for file: URL, within boundary: URL) -> URL {
        let limit = boundary.standardizedFileURL.path
        var directory = file.deletingLastPathComponent().standardizedFileURL
        let fileManager = FileManager.default
        while directory.path.hasPrefix(limit) {
            if rootMarkers.contains(where: { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }) { return directory }
            if directory.path == limit { break }
            directory = directory.deletingLastPathComponent()
        }
        return file.path.hasPrefix(limit + "/") ? boundary.standardizedFileURL : file.deletingLastPathComponent().standardizedFileURL
    }
}

/// GUI apps start with launchd's minimal PATH, while language servers live on the login shell's
/// (Homebrew, npm, pyenv) and some are scripts that need it too (pyright is `#!/usr/bin/env node`).
/// Each binary is resolved once through the login shell and cached, and so is that PATH.
public final class LoginShell: @unchecked Sendable {
    public static let shared = LoginShell()

    private let shell: String
    private let timeout: Duration
    private let lock = NSLock()
    private var resolved: [String: URL?] = [:]
    private var cachedPath: String?
    private var cachedEditor: String??

    public init(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", timeout: Duration = .seconds(10)) {
        self.shell = shell
        self.timeout = timeout
    }

    /// Absolute path of `command` on the login PATH, or nil when it isn't installed.
    public func resolve(_ command: String) -> URL? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? URL(fileURLWithPath: command) : nil
        }
        if let cached = lock.withLock({ resolved[command] }) { return cached }
        let found = run("command -v \(Self.quote(command))")
            .split(whereSeparator: \.isNewline).last
            .map(String.init)
            .flatMap { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        lock.withLock { resolved[command] = .some(found) }
        return found
    }

    /// The app environment with the login shell's PATH, for server processes.
    public var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let path = lock.withLock { cachedPath } ?? {
            // A marker separates the value from anything rc files print.
            let output = run("printf '\\n__CANVAS_PATH__%s' \"$PATH\"")
            let value = output.contains("__CANVAS_PATH__") ? output.components(separatedBy: "__CANVAS_PATH__").last ?? "" : ""
            let path = value.isEmpty ? (environment["PATH"] ?? "/usr/bin:/bin") : value
            lock.withLock { cachedPath = path }
            return path
        }()
        environment["PATH"] = path
        return environment
    }

    /// The editor the user's shell names: `$VISUAL`, else `$EDITOR`; nil when neither is set.
    /// Read once from an interactive login shell, since editors are often exported only in
    /// interactive rc files (.zshrc), started with only the basic session variables, so what the
    /// app inherited from whatever launched it doesn't mask the user's setup. Blocking: call it
    /// off the main thread and out of Swift tasks.
    public var editor: String? {
        if let cached = lock.withLock({ cachedEditor }) { return cached }
        let output = run("printf '\\n__CANVAS_EDITOR__%s' \"${VISUAL:-$EDITOR}\"", interactive: true, freshEnvironment: true)
        let value = output.components(separatedBy: "__CANVAS_EDITOR__").dropFirst().last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let editor = value.isEmpty ? nil : value
        lock.withLock { cachedEditor = .some(editor) }
        return editor
    }

    /// What a fresh login session starts with, before rc files run.
    private static let sessionVariables = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"]

    private static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs `$SHELL -lc script` (`-lic` when `interactive`) in its own process group and reads
    /// its output until EOF or the deadline. At the deadline the whole group is killed and the read
    /// abandoned: rc files can start children that outlive the shell and keep the output pipe open.
    /// `freshEnvironment`: only the session variables and a system PATH, not the app's environment.
    private func run(_ script: String, interactive: Bool = false, freshEnvironment: Bool = false) -> String {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return "" }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        defer { close(readEnd) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let words: [String] = [shell, interactive ? "-lic" : "-lc", script]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let inherited = ProcessInfo.processInfo.environment
        let variables = Self.sessionVariables.compactMap { name in inherited[name].map { "\(name)=\($0)" } } + ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        let fresh: [UnsafeMutablePointer<CChar>?] = variables.map { strdup($0) } + [nil]
        defer { fresh.forEach { free($0) } }
        let spawned = freshEnvironment ? posix_spawn(&pid, shell, &actions, &attributes, argv, fresh) : posix_spawn(&pid, shell, &actions, &attributes, argv, environ)
        close(writeEnd)
        guard spawned == 0 else { return "" }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ContinuousClock.now + timeout
        var reaped = false
        var eof = false
        var status: Int32 = 0
        reading: while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            // Short slices: once the shell has exited, what it printed is complete even if a
            // child it started still holds the pipe open.
            var poller = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(100, max(1, remaining.seconds * 1000))))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                if !reaped, waitpid(pid, &status, WNOHANG) == pid { reaped = true }
                if reaped {
                    // Drain what's already buffered, then stop.
                    while poll(&poller, 1, 0) > 0 {
                        let count = read(readEnd, &buffer, buffer.count)
                        guard count > 0 else {
                            eof = true
                            break reading
                        }
                        output.append(contentsOf: buffer[0..<count])
                    }
                    break
                }
                continue
            }
            let count = read(readEnd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 {
                eof = true
                break
            }
            output.append(contentsOf: buffer[0..<count])
        }
        // Anything in the group still holding the pipe (a hung shell, or a child an rc file
        // left behind) is ended with it.
        if !eof { kill(-pid, SIGKILL) }
        if !reaped { while waitpid(pid, &status, 0) < 0, errno == EINTR {} }
        return String(decoding: output, as: UTF8.self)
    }
}
