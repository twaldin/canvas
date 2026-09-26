import Foundation

/// How to run one language's server and which files and project roots belong to it.
public struct LanguageServerConfig: Sendable, Hashable {
    /// Registry key, e.g. "swift".
    public var language: String
    /// Binary name looked up on the login PATH, or an absolute path.
    public var command: String
    public var arguments: [String]
    /// File extension (lowercased, no dot) → LSP languageId.
    public var languageIDs: [String: String]
    /// Files that mark a project root; the nearest one above a file (within the board root) wins.
    public var rootMarkers: [String]

    public init(language: String, command: String, arguments: [String] = [], languageIDs: [String: String], rootMarkers: [String]) {
        self.language = language
        self.command = command
        self.arguments = arguments
        self.languageIDs = languageIDs
        self.rootMarkers = rootMarkers
    }

    public static let defaults: [LanguageServerConfig] = [
        LanguageServerConfig(language: "swift", command: "sourcekit-lsp", languageIDs: ["swift": "swift"],
                             rootMarkers: ["Package.swift", "compile_commands.json", "buildServer.json"]),
        LanguageServerConfig(language: "python", command: "pyright-langserver", arguments: ["--stdio"], languageIDs: ["py": "python", "pyi": "python"],
                             rootMarkers: ["pyrightconfig.json", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"]),
        LanguageServerConfig(language: "typescript", command: "typescript-language-server", arguments: ["--stdio"],
                             languageIDs: ["ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
                                           "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascriptreact"],
                             rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json"]),
        LanguageServerConfig(language: "go", command: "gopls", languageIDs: ["go": "go"], rootMarkers: ["go.work", "go.mod"]),
        LanguageServerConfig(language: "rust", command: "rust-analyzer", languageIDs: ["rs": "rust"], rootMarkers: ["Cargo.toml"]),
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

    private let lock = NSLock()
    private var resolved: [String: URL?] = [:]
    private var cachedPath: String?

    public init() {}

    /// Absolute path of `command` on the login PATH, or nil when it isn't installed.
    public func resolve(_ command: String) -> URL? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? URL(fileURLWithPath: command) : nil
        }
        if let cached = lock.withLock({ resolved[command] }) { return cached }
        let found = Self.run("command -v \(Self.quote(command))")
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
            let output = Self.run("printf '\\n__CANVAS_PATH__%s' \"$PATH\"")
            let value = output.contains("__CANVAS_PATH__") ? output.components(separatedBy: "__CANVAS_PATH__").last ?? "" : ""
            let path = value.isEmpty ? (environment["PATH"] ?? "/usr/bin:/bin") : value
            lock.withLock { cachedPath = path }
            return path
        }()
        environment["PATH"] = path
        return environment
    }

    private static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a login shell with a deadline so a hanging rc file can't stall the language service.
    private static func run(_ script: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-lc", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let pid = process.processIdentifier
        let deadline = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}
