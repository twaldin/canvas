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
    /// Nothing to read: the file doesn't exist (on disk, or at the pinned commit), or the
    /// pinned commit doesn't. A stale anchor on a file that is there is not missing.
    public var missing = false

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
        func failed(_ reason: String, missing: Bool) -> NoteExcerpt {
            NoteExcerpt(path: path, range: nil, lines: captured ?? [], status: .stale(reason), missing: missing)
        }
        do {
            text = try await read(path, commit: fence.commit, root: root)
        } catch NoteSourceError.invalidRevision(let commit) {
            return failed("\"\(commit)\" is not a commit", missing: false)
        } catch NoteSourceError.unknownCommit(let commit) {
            return failed("unknown commit \(commit)", missing: true)
        } catch NoteSourceError.notAtCommit(let commit) {
            return failed("\(path) does not exist at \(commit)", missing: true)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return failed("no file \(path)", missing: true)
        } catch {
            let place = fence.commit.map { "\(path) at \($0)" } ?? path
            return failed("cannot read \(place)", missing: false)
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

    /// File text; a pinned commit reads through `git show` (see `showCommand`). A failed show
    /// tells a commit that lacks the file from one that doesn't exist.
    static func read(_ path: String, commit: String?, root: URL) async throws -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        guard let commit else { return try await offPool { Result { try String(contentsOf: url, encoding: .utf8) } }.get() }
        let show = try showCommand(path, commit: commit, root: root)
        let data: Data
        do {
            data = try await GitRunner.shared.run(show.arguments, in: show.directory, maxOutput: maxOutput, timeout: timeout)
        } catch GitError.failed {
            let exists = try? await GitRunner.shared.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(commit)^{commit}"], in: show.directory, timeout: timeout)
            throw exists == nil ? NoteSourceError.unknownCommit(commit) : NoteSourceError.notAtCommit(commit)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    /// `git show --end-of-options <commit>:./<path>` and where to run it. A path under the board
    /// root runs in the root, relative to it (the root may be a subdirectory of the repository).
    /// A file elsewhere, typically in another worktree of the repository, runs in its own
    /// worktree with the path relative to that: every worktree shares the object database, but
    /// only its own top level makes the path mean something. The revision comes from markdown
    /// anyone can write, so it may not look like an option or carry its own `:path`.
    static func showCommand(_ path: String, commit: String, root: URL) throws -> (arguments: [String], directory: URL) {
        guard isRevision(commit) else { throw NoteSourceError.invalidRevision(commit) }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let rootPath = root.standardizedFileURL.path
        let absolute = url.standardizedFileURL.path
        if absolute.hasPrefix(rootPath + "/") {
            return (["show", "--end-of-options", "\(commit):./\(absolute.dropFirst(rootPath.count + 1))"], root)
        }
        guard let worktree = GitWorktree.containing(absolute), let relative = worktree.relativePath(of: absolute) else {
            throw NoteSourceError.notAtCommit(commit)
        }
        return (["show", "--end-of-options", "\(commit):./\(relative)"], URL(fileURLWithPath: worktree.toplevel))
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
        guard let data = try? await GitRunner.shared.run(["grep", "-l", "-I", "-E", "-e", pattern], in: root, allowedStatus: [0, 1], maxOutput: maxOutput, timeout: timeout),
              let output = String(data: data, encoding: .utf8) else { return nil }
        let candidates = output.split(separator: "\n").map(String.init)
        return await offPool {
            candidates.first { candidate in
                guard let text = try? String(contentsOf: root.appendingPathComponent(candidate), encoding: .utf8) else { return false }
                return NoteAnchor.symbolRange(symbol, in: lines(of: text)) != nil
            }
        }
    }

    /// Git for a fence is bounded: a pinned file larger than this is not an excerpt, and a stuck
    /// git can't hold one of the app's two git slots.
    static let maxOutput = 32 << 20
    static let timeout: TimeInterval = 20

    /// Lines without the empty string after a trailing newline.
    public static func lines(of text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }
}

public enum NoteSourceError: Error, Equatable {
    /// A pinned fence's `commit=` doesn't look like a revision (e.g. it looks like an option).
    case invalidRevision(String)
    /// The pinned commit doesn't exist in the file's repository.
    case unknownCommit(String)
    /// The commit exists but has no file at the path (or the path is in no repository).
    case notAtCommit(String)
}
