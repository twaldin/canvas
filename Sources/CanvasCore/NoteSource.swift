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

    public var isStale: Bool {
        if case .stale = status { true } else { false }
    }
}

public enum NoteSource {
    /// Resolve a fence against disk (or `git show` for a pinned commit). `captured` is the text the
    /// range showed when first resolved; it re-finds the range when lines move and stands in when
    /// the anchor is lost.
    @concurrent
    public static func excerpt(for fence: NoteFence, root: URL, captured: [String]?) async -> NoteExcerpt {
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
        } catch {
            let place = fence.commit.map { "\(path) at \($0)" } ?? path
            return NoteExcerpt(path: path, range: nil, lines: captured ?? [], status: .stale("cannot read \(place)"))
        }
        let source = lines(of: text)
        let resolution = NoteAnchor.resolve(fence, in: source, captured: captured)
        guard let range = resolution.range else {
            return NoteExcerpt(path: path, range: nil, lines: captured ?? [], status: resolution.status)
        }
        return NoteExcerpt(path: path, range: range, lines: Array(source[(range.start - 1)..<range.end]), status: resolution.status)
    }

    /// File text; a pinned commit reads through `git show <commit>:./<path>` so the path stays
    /// relative to the board root rather than the repository root.
    static func read(_ path: String, commit: String?, root: URL) async throws -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        guard let commit else { return try String(contentsOf: url, encoding: .utf8) }
        let rootPath = root.standardizedFileURL.path
        let absolute = url.standardizedFileURL.path
        let relative = absolute.hasPrefix(rootPath + "/") ? String(absolute.dropFirst(rootPath.count + 1)) : path
        let data = try await NoteGit.run(["show", "\(commit):./\(relative)"], in: root)
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    /// First tracked file that declares `symbol` (its last dotted component), found by `git grep`
    /// with the strongest declaration keywords.
    static func locate(symbol: String, root: URL) async -> String? {
        guard let name = symbol.split(separator: ".").last.map(String.init), !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) else { return nil }
        let pattern = "(^|[^[:alnum:]_.$])(\(NoteAnchor.declarationKeywords)|const|let|var)[[:space:]]+([(][^)]*[)][[:space:]]*)?\(name.replacingOccurrences(of: "$", with: "\\$"))([^[:alnum:]_$]|$)"
        guard let data = try? await NoteGit.run(["grep", "-l", "-I", "-E", "-e", pattern], in: root, allowedStatus: [0, 1]),
              let output = String(data: data, encoding: .utf8) else { return nil }
        for candidate in output.split(separator: "\n").map(String.init) {
            guard let text = try? String(contentsOf: root.appendingPathComponent(candidate), encoding: .utf8) else { continue }
            if NoteAnchor.symbolRange(symbol, in: lines(of: text)) != nil { return candidate }
        }
        return nil
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
}

/// Runs git for note fences, at most two processes at a time (docs/design.md, Performance).
enum NoteGit {
    private static let limiter = Limiter(permits: 2)

    static func run(_ args: [String], in directory: URL, allowedStatus: Set<Int32> = [0]) async throws -> Data {
        await limiter.acquire()
        do {
            let data = try await launch(args, in: directory, allowedStatus: allowedStatus)
            await limiter.release()
            return data
        } catch {
            await limiter.release()
            throw error
        }
    }

    private static func launch(_ args: [String], in directory: URL, allowedStatus: Set<Int32>) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            // Reading a pipe to EOF blocks, so it runs on a GCD thread, not the cooperative pool.
            DispatchQueue.global(qos: .userInitiated).async {
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
                do {
                    try process.run()
                } catch {
                    return continuation.resume(throwing: NoteGitError.launch("\(error)"))
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errors = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if allowedStatus.contains(process.terminationStatus) {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NoteGitError.failed(status: process.terminationStatus, stderr: String(decoding: errors, as: UTF8.self)))
                }
            }
        }
    }

    private actor Limiter {
        private var available: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(permits: Int) { available = permits }

        func acquire() async {
            if available > 0 {
                available -= 1
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
        }
    }
}
