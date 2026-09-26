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
        } catch NoteSourceError.invalidRevision(let commit) {
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
        guard let commit else { return try await offPool { Result { try String(contentsOf: url, encoding: .utf8) } }.get() }
        let data = try await GitRunner.shared.run(try showArguments(path, commit: commit, root: root), in: root, maxOutput: maxOutput, timeout: timeout)
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    /// `git show --end-of-options <commit>:./<path>`. The revision comes from markdown anyone can
    /// write, so it may not look like an option or carry its own `:path`.
    static func showArguments(_ path: String, commit: String, root: URL) throws -> [String] {
        guard isRevision(commit) else { throw NoteSourceError.invalidRevision(commit) }
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
}
