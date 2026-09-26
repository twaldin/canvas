import Foundation

/// What an anchored fence shows: the resolved range of a real file (or, when stale, the text it
/// last showed). Built off the main actor by `NoteSource.excerpt`.
public struct NoteExcerpt: Equatable, Sendable {
    /// The file the fence points at, as written or as found by a workspace symbol search.
    public var path: String
    public var range: LineRange?
    /// The range's lines; for a stale anchor, the captured text it used to show (possibly empty).
    public var lines: [String]
    public var status: NoteAnchor.Status
    /// For a proposal: the range (old) against the fence body (new), computed here, off the main
    /// actor, because a whole-file proposal can be large.
    public var diff: [NoteDiff.Line]?
    /// Lines in the file, so a proposal row appended past its range knows whether a real line
    /// follows it.
    public var fileLineCount = 0

    public var isStale: Bool {
        if case .stale = status { true } else { false }
    }

    /// For each `diff` row, the real source line it mentions: its own line for kept and removed
    /// rows; for an added row the line it would be inserted before, or, appended at the end of
    /// the file where there is none, the last line (which it follows).
    public var proposalLines: [Int] {
        guard let diff, let range else { return [] }
        var next = range.start
        return diff.map { entry in
            switch entry {
            case .same(let old, _, _), .removed(let old, _):
                next = range.start + old + 1
                return range.start + old
            case .added:
                return next <= fileLineCount ? next : max(1, fileLineCount)
            }
        }
    }
}

public enum NoteSource {
    /// Resolve a fence against disk (or `git show` for a pinned commit). `captured` is the text the
    /// range showed when first resolved; it re-finds the range when lines move and stands in when
    /// the anchor is lost. `body` is the fence's own text (see `NoteAnchor.resolve`).
    @concurrent
    public static func excerpt(for fence: NoteFence, root: URL, captured: [String]?, body: [String] = []) async -> NoteExcerpt {
        var path = fence.path
        if path == nil, let symbol = fence.symbol {
            path = await locate(symbol: symbol, root: root)
        }
        guard let path else {
            return NoteExcerpt(path: "", range: nil, lines: captured ?? [], status: .stale("symbol \(fence.symbol ?? "") not found in the workspace"))
        }
        let text: String
        do {
            text = try await read(path, commit: fence.commit, root: root)
        } catch NoteGitError.invalidRevision(let commit) {
            return NoteExcerpt(path: path, range: nil, lines: captured ?? [], status: .stale("\"\(commit)\" is not a commit"))
        } catch {
            let place = fence.commit.map { "\(path) at \($0)" } ?? path
            return NoteExcerpt(path: path, range: nil, lines: captured ?? [], status: .stale("cannot read \(place)"))
        }
        let source = lines(of: text)
        let resolution = NoteAnchor.resolve(fence, in: source, captured: captured, body: body)
        guard let range = resolution.range else {
            return NoteExcerpt(path: path, range: nil, lines: captured ?? [], status: resolution.status, fileLineCount: source.count)
        }
        let shown = Array(source[(range.start - 1)..<range.end])
        let diff = fence.mode == .propose ? NoteDiff.lines(shown, body) : nil
        return NoteExcerpt(path: path, range: range, lines: shown, status: resolution.status, diff: diff, fileLineCount: source.count)
    }

    /// File text; a pinned commit reads through `git show <commit>:./<path>` so the path stays
    /// relative to the board root rather than the repository root.
    static func read(_ path: String, commit: String?, root: URL) async throws -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        guard let commit else { return try await blocking { try String(contentsOf: url, encoding: .utf8) } }
        let data = try await NoteGit.run(try showArguments(path, commit: commit, root: root), in: root)
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    /// `git show --end-of-options <commit>:./<path>`. The revision comes from markdown anyone can
    /// write, so it may not look like an option or carry its own `:path`.
    static func showArguments(_ path: String, commit: String, root: URL) throws -> [String] {
        guard isRevision(commit) else { throw NoteGitError.invalidRevision(commit) }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let rootPath = root.standardizedFileURL.path
        let absolute = url.standardizedFileURL.path
        let relative = absolute.hasPrefix(rootPath + "/") ? String(absolute.dropFirst(rootPath.count + 1)) : path
        return ["show", "--end-of-options", "\(commit):./\(relative)"]
    }

    static func isRevision(_ text: String) -> Bool {
        guard let first = text.first, first != "-" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || "._~^/-".contains($0) }
    }

    /// First tracked file that declares `symbol` (its last dotted component), found by `git grep`
    /// with the strongest declaration keywords.
    static func locate(symbol: String, root: URL) async -> String? {
        guard let name = symbol.split(separator: ".").last.map(String.init), !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) else { return nil }
        let pattern = "(^|[^[:alnum:]_.$])(\(NoteAnchor.declarationKeywords)|const|let|var)[[:space:]]+([(][^)]*[)][[:space:]]*)?\(name.replacingOccurrences(of: "$", with: "\\$"))([^[:alnum:]_$]|$)"
        guard let data = try? await NoteGit.run(["grep", "-l", "-I", "-E", "-e", pattern], in: root, allowedStatus: [0, 1]),
              let output = String(data: data, encoding: .utf8) else { return nil }
        let candidates = output.split(separator: "\n").map(String.init)
        return try? await blocking {
            candidates.first { candidate in
                guard let text = try? String(contentsOf: root.appendingPathComponent(candidate), encoding: .utf8) else { return false }
                return NoteAnchor.symbolRange(symbol, in: lines(of: text)) != nil
            }
        }
    }

    /// Runs blocking file work on a GCD thread: a blocked cooperative-pool thread starves every
    /// other task in the app, the socket servers' included.
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result(catching: work)) }
        }
    }

    /// Lines without the empty string after a trailing newline.
    public static func lines(of text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }
}

public enum NoteGitError: Error, Equatable {
    case failed(status: Int32, stderr: String)
    case launch(String)
    case timedOut
    case invalidRevision(String)
}

/// Runs git for note fences, at most two processes at a time (docs/design.md, Performance).
/// Cancelling the calling task drops a queued request or terminates the running process.
enum NoteGit {
    private static let limiter = Limiter(permits: 2)
    static let timeout: TimeInterval = 20
    /// Diagnostics past this are dropped; stdout past `maxOutput` fails the command.
    static let maxDiagnostics = 4_096
    static let maxOutput = 32 << 20

    static func run(_ args: [String], in directory: URL, allowedStatus: Set<Int32> = [0]) async throws -> Data {
        try await limiter.acquire()
        do {
            try Task.checkCancellation()
            let data = try await launch(args, in: directory, allowedStatus: allowedStatus)
            await limiter.release()
            return data
        } catch {
            await limiter.release()
            throw error
        }
    }

    private static func launch(_ args: [String], in directory: URL, allowedStatus: Set<Int32>) async throws -> Data {
        let handle = Handle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Reading pipes to EOF blocks, so it runs on a GCD thread, not the cooperative pool.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try execute(args, in: directory, allowedStatus: allowedStatus, timeout: timeout, handle: handle) })
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Runs git to completion on the calling thread. stdout and stderr drain concurrently, so a
    /// chatty failure can't block git on a full stderr pipe while we wait for stdout.
    static func execute(_ args: [String], in directory: URL, allowedStatus: Set<Int32>, timeout: TimeInterval, handle: Handle?) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotepath=off"] + args
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_PAGER"] = "cat"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        if handle?.isCancelled == true { throw CancellationError() }
        do {
            try process.run()
        } catch {
            throw NoteGitError.launch("\(error)")
        }
        let watchdog = Handle()
        if handle?.attach(process) == false { process.terminate() }
        watchdog.attach(process)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { watchdog.expire() }

        let diagnostics = Diagnostics()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let reader = err.fileHandleForReading
            while case let chunk = reader.availableData, !chunk.isEmpty { diagnostics.append(chunk) }
            stderrDone.signal()
        }
        var data = Data()
        let reader = out.fileHandleForReading
        var overflow = false
        while case let chunk = reader.availableData, !chunk.isEmpty {
            if overflow { continue }
            if data.count + chunk.count > maxOutput {
                overflow = true
                process.terminate()
                continue
            }
            data.append(chunk)
        }
        stderrDone.wait()
        process.waitUntilExit()
        watchdog.finish()
        if handle?.isCancelled == true { throw CancellationError() }
        if watchdog.expired { throw NoteGitError.timedOut }
        if overflow { throw NoteGitError.failed(status: process.terminationStatus, stderr: "output larger than \(maxOutput) bytes") }
        guard process.terminationReason == .exit, allowedStatus.contains(process.terminationStatus) else {
            throw NoteGitError.failed(status: process.terminationStatus, stderr: diagnostics.text)
        }
        return data
    }

    /// The running process of one request, for cancellation and the timeout watchdog.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var finished = false
        private(set) var expired = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        /// false when the request was cancelled before the process started.
        @discardableResult
        func attach(_ process: Process) -> Bool {
            lock.withLock {
                self.process = process
                return !cancelled
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if !finished, let process, process.isRunning { process.terminate() }
            }
        }

        func expire() {
            lock.withLock {
                guard !finished, let process, process.isRunning else { return }
                expired = true
                process.terminate()
            }
        }

        func finish() {
            lock.withLock { finished = true }
        }
    }

    private final class Diagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.withLock {
                if data.count < NoteGit.maxDiagnostics { data.append(chunk.prefix(NoteGit.maxDiagnostics - data.count)) }
            }
        }

        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    /// Permits for concurrent git processes; a waiter whose task is cancelled leaves the queue.
    private actor Limiter {
        private var available: Int
        private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
        private var nextID: UInt64 = 0

        init(permits: Int) { available = permits }

        func acquire() async throws {
            try Task.checkCancellation()
            if available > 0 {
                available -= 1
                return
            }
            let id = nextID
            nextID += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters.append((id, continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        private func cancel(_ id: UInt64) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }

        /// Hands the permit to the next waiter, or returns it to the pool.
        func release() {
            if waiters.isEmpty { available += 1 } else { waiters.removeFirst().continuation.resume() }
        }
    }
}
