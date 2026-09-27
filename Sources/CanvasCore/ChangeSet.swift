import Foundation

/// What a changes tile reviews (`ChangesProps`): the diff base (default `HEAD`: the uncommitted
/// work, what an agent just did; `merge-base`; or a commit) and the files or directories it is
/// limited to (board-relative or absolute; none: the board root).
public struct ChangesSpec: Equatable, Sendable {
    public var baseProp: String
    public var paths: [String]

    public init(_ props: JSONValue) {
        baseProp = props["base"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD"
        paths = props["paths"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
    }

    public var base: DiffBase { DiffBase(prop: baseProp) }
}

/// One row of a unified diff: an unchanged line around or between changes, a removed base line,
/// or an added working-tree line, with its line numbers (1-based) on the sides it is on.
public struct ChangeLine: Equatable, Sendable {
    public enum Kind: Sendable { case context, removed, added }

    public var kind: Kind
    public var old: Int?
    public var new: Int?

    public init(kind: Kind, old: Int?, new: Int?) {
        self.kind = kind
        self.old = old
        self.new = new
    }
}

/// Whether the index holds a hunk: `unstaged` (the working tree differs from the index there),
/// `staged` (the index has it), or `committed` (HEAD already has it: a base older than HEAD).
public enum HunkStatus: String, Sendable, Equatable {
    case unstaged, staged, committed
}

/// One hunk as `git diff -U3` groups it: changes at most 2 × 3 unchanged lines apart, with 3
/// lines of context around them.
public struct ChangeHunk: Equatable, Sendable {
    public var mappings: [LineRangeMapping]
    public var lines: [ChangeLine]
    public var status: HunkStatus
    /// The span the lines cover on each side, as a patch header counts it: a zero count starts
    /// at the line before.
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int

    public init(mappings: [LineRangeMapping], old: SideText, new: SideText, status: HunkStatus = .unstaged, context: Int = 3) {
        self.mappings = mappings
        self.status = status
        let lines = Self.lines(old: old, new: new, mappings: mappings, context: context)
        self.lines = lines
        let olds = lines.compactMap(\.old), news = lines.compactMap(\.new)
        oldCount = olds.count
        newCount = news.count
        oldStart = olds.first ?? max(0, (mappings.first?.original.lowerBound ?? 1) - 1)
        newStart = news.first ?? max(0, (mappings.first?.modified.lowerBound ?? 1) - 1)
    }

    public var header: String {
        func span(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
        return "@@ -\(span(oldStart, oldCount)) +\(span(newStart, newCount)) @@"
    }

    public var added: Int { mappings.reduce(0) { $0 + $1.modified.count } }
    public var removed: Int { mappings.reduce(0) { $0 + $1.original.count } }

    /// What a mention of the whole hunk names: its working-tree lines, or its base lines when it
    /// only removes.
    public var mentionLines: (side: DiffSide, lines: LineRange) { DiffHunk(mappings: mappings).mentionLines }

    /// Working-tree lines the hunk's changes span (an empty range for a pure deletion sits
    /// before the line after it).
    public var modified: Range<Int> { mappings.first!.modified.lowerBound..<mappings.last!.modified.upperBound }

    /// The unified-diff rows of `mappings` (one hunk's changes) between `old` and `new`, with up
    /// to `context` unchanged lines before, between, and after them.
    public static func lines(old: SideText, new: SideText, mappings: [LineRangeMapping], context: Int = 3) -> [ChangeLine] {
        guard let first = mappings.first else { return [] }
        var lines: [ChangeLine] = []
        let lead = max(0, min(context, first.original.lowerBound - 1, first.modified.lowerBound - 1))
        var oldLine = first.original.lowerBound - lead, newLine = first.modified.lowerBound - lead
        for mapping in mappings {
            while newLine < mapping.modified.lowerBound, oldLine < mapping.original.lowerBound {
                lines.append(ChangeLine(kind: .context, old: oldLine, new: newLine))
                oldLine += 1
                newLine += 1
            }
            for line in mapping.original { lines.append(ChangeLine(kind: .removed, old: line, new: nil)) }
            for line in mapping.modified { lines.append(ChangeLine(kind: .added, old: nil, new: line)) }
            oldLine = mapping.original.upperBound
            newLine = mapping.modified.upperBound
        }
        let trail = max(0, min(context, old.lineCount - oldLine + 1, new.lineCount - newLine + 1))
        for _ in 0..<trail {
            lines.append(ChangeLine(kind: .context, old: oldLine, new: newLine))
            oldLine += 1
            newLine += 1
        }
        return lines
    }

    /// Whether two line ranges of the same side meet: overlapping, or an empty range (a
    /// deletion's position) at or touching the other.
    static func touches(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        if a.isEmpty, b.isEmpty { return a.lowerBound == b.lowerBound }
        if a.isEmpty { return b.lowerBound <= a.lowerBound && a.lowerBound <= b.upperBound }
        if b.isEmpty { return a.lowerBound <= b.lowerBound && b.lowerBound <= a.upperBound }
        return a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    /// The index's view of a hunk from the working-tree side (every range in working-tree
    /// lines): `unstaged` where the index differs from the working tree over any of its changes
    /// (`unstaged` = index → working tree changes; an untracked file is all unstaged), else
    /// `staged` when HEAD differs there too (`head` = HEAD → working tree changes; nil when the
    /// base is HEAD, whose hunks HEAD always lacks), else `committed`.
    public static func status(of mappings: [LineRangeMapping], tracked: Bool, unstaged: [LineRangeMapping], head: [LineRangeMapping]?) -> HunkStatus {
        guard tracked else { return .unstaged }
        let ranges = mappings.map(\.modified)
        if unstaged.contains(where: { change in ranges.contains { touches($0, change.modified) } }) { return .unstaged }
        guard let head else { return .staged }
        return head.contains(where: { change in ranges.contains { touches($0, change.modified) } }) ? .staged : .committed
    }
}

public enum ChangeStatus: String, Sendable, Equatable {
    case added, modified, deleted, renamed
}

/// One changed file: both sides' text (the base version, the working tree), the hunks between
/// them, and its highlighting once `ChangeSet.highlight` ran.
public struct ChangedFile: Sendable {
    /// Relative to the repository's top level (what git names it).
    public var path: String
    /// A renamed file's name in the base.
    public var oldPath: String?
    /// `path` as the board names it: relative to the board root when under it, else absolute.
    public var boardPath: String
    public var oldBoardPath: String?
    public var status: ChangeStatus
    public var old: SideText
    public var new: SideText
    /// Git file modes (`100644`, `100755`); nil where the side has no file.
    public var oldMode: String?
    public var newMode: String?
    /// In the index (false for untracked files).
    public var tracked: Bool
    public var hunks: [ChangeHunk]
    /// Why there are no hunks to show (binary, too large, a submodule, only the mode changed).
    public var notice: String?
    public var oldSyntax = SyntaxLines.empty
    public var newSyntax = SyntaxLines.empty
    public var oldSymbols: [SyntaxSymbol] = []
    public var newSymbols: [SyntaxSymbol] = []

    public var added: Int { hunks.reduce(0) { $0 + $1.added } }
    public var removed: Int { hunks.reduce(0) { $0 + $1.removed } }

    /// A hunk's changes a patch can carry: all of them for a created or deleted file (one hunk).
    public var mappings: [LineRangeMapping] { hunks.flatMap(\.mappings) }

    /// The innermost declaration around a line of one side.
    public func symbol(line: Int, side: DiffSide) -> String? {
        (side == .old ? oldSymbols : newSymbols).filter { $0.lines.contains(line) }.min { $0.lines.count < $1.lines.count }?.name
    }
}

/// What a changes tile shows: every file that differs between the base and the working tree
/// (untracked files as added) under its paths, with hunks and their index status. Loaded by
/// `load`, all git through `GitDiffEngine` and `GitRunner`, off the main thread.
public struct ChangeSet: Sendable {
    public var repository: URL?
    /// Full SHA of the base; nil when there is none (see `notice`).
    public var base: String?
    /// How the base was chosen (`HEAD`, `merge-base with main`, the commit as written).
    public var baseLabel: String
    public var files: [ChangedFile]
    /// Why nothing can be listed (not a repository, no commits, a path outside it).
    public var notice: String?
    /// Changed files past `maxFiles`, not loaded.
    public var omitted: Int

    public init(repository: URL? = nil, base: String? = nil, baseLabel: String = "", files: [ChangedFile] = [], notice: String? = nil, omitted: Int = 0) {
        self.repository = repository
        self.base = base
        self.baseLabel = baseLabel
        self.files = files
        self.notice = notice
        self.omitted = omitted
    }

    /// Files a tile loads at most; the rest are counted in `omitted`.
    public static let maxFiles = 300
    /// Sides longer than this aren't highlighted.
    static let maxHighlightLines = 20_000

    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }

    /// The header's summary: `3 files · +40 −12 · HEAD 1a2b3c4`.
    public var summary: String {
        if let notice { return notice }
        let base = base.map { " · \(baseLabel) \($0.prefix(7))" } ?? ""
        guard !files.isEmpty else { return "no changes\(base)" }
        let count = files.count + omitted
        return "\(count) file\(count == 1 ? "" : "s") · +\(added) −\(removed)\(base)"
    }

    // MARK: Loading

    /// The changes between `spec`'s base and the working tree of the repository containing
    /// `root`, limited to `spec.paths` (else `root`). `highlight` also parses both sides with
    /// tree-sitter (tiles; measuring and `object.get` don't need it).
    public static func load(root: URL, spec: ChangesSpec, highlight: Bool = true, engine: GitDiffEngine = .shared, runner: GitRunner = .shared) async -> ChangeSet {
        let directory = GitDiffEngine.existingAncestor(of: root)
        guard let output = try? await runner.run(["rev-parse", "--path-format=absolute", "--show-toplevel"], in: directory),
              let top = String(decoding: output, as: UTF8.self).split(separator: "\n").first else {
            return ChangeSet(notice: "not in a git repository")
        }
        let toplevel = URL(fileURLWithPath: String(top))
        let specs: [String]
        do {
            specs = try pathspecs(spec.paths, root: root, toplevel: toplevel)
        } catch let failure as ChangesFailure {
            return ChangeSet(repository: toplevel, notice: failure.message)
        } catch {
            return ChangeSet(repository: toplevel, notice: "\(error)")
        }
        let resolved = await GitDiffEngine.resolve(spec.base, in: toplevel, runner: runner)
        guard let sha = resolved.sha else { return ChangeSet(repository: toplevel, baseLabel: resolved.label, notice: resolved.label) }
        // Held while loading: the engine resolves the base and the repository once for all files.
        let held = await engine.retain(containing: toplevel.appendingPathComponent(".canvas-changes"))
        defer { if let held { Task { await engine.release(held) } } }

        var entries: [Entry] = []
        if let raw = try? await runner.run(["--literal-pathspecs", "diff", "--raw", "-z", "-M", "--no-color", "--no-ext-diff", "--no-textconv", sha, "--"] + specs, in: toplevel) {
            entries = parseRaw(raw)
        }
        let listed = Set(entries.map(\.path))
        if let others = try? await runner.run(["--literal-pathspecs", "ls-files", "-z", "--others", "--exclude-standard", "--"] + specs, in: toplevel) {
            for record in others.split(separator: 0) {
                let path = String(decoding: record, as: UTF8.self)
                guard !listed.contains(path) else { continue }
                entries.append(Entry(status: .added, path: path, oldPath: nil, oldMode: nil, newMode: nil, tracked: false))
            }
        }
        entries.sort { $0.path < $1.path }
        let omitted = max(0, entries.count - maxFiles)
        let selected = Array(entries.prefix(maxFiles))
        guard !selected.isEmpty else { return ChangeSet(repository: toplevel, base: sha, baseLabel: resolved.label) }

        // Index → working tree, and HEAD → working tree for a base older than HEAD: which
        // hunks the index already holds.
        let paths = selected.map(\.path)
        let unstaged = await workingTreeChanges(against: nil, paths: paths, in: toplevel, runner: runner)
        let headSHA = await GitDiffEngine.resolve(.head, in: toplevel, runner: runner).sha
        var head: [String: [LineRangeMapping]]?
        if let headSHA, headSHA != sha { head = await workingTreeChanges(against: headSHA, paths: paths, in: toplevel, runner: runner) }
        let headChanges = head

        let files = await withTaskGroup(of: (Int, ChangedFile?).self) { group in
            for (index, entry) in selected.enumerated() {
                group.addTask {
                    let file = await Self.file(entry, base: sha, diffBase: spec.base, root: root, toplevel: toplevel, engine: engine, runner: runner,
                                               unstaged: unstaged[entry.path] ?? [], head: headChanges.map { $0[entry.path] ?? [] })
                    return (index, file)
                }
            }
            var found: [(Int, ChangedFile)] = []
            for await (index, file) in group { if let file { found.append((index, file)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let set = ChangeSet(repository: toplevel, base: sha, baseLabel: resolved.label, files: files, omitted: omitted)
        return highlight ? await offPool { set.highlighted() } : set
    }

    /// Both sides of every file parsed with tree-sitter (highlighting and enclosing symbols).
    func highlighted() -> ChangeSet {
        var set = self
        for index in set.files.indices {
            let file = set.files[index]
            guard let language = SyntaxLanguage(path: file.path) else { continue }
            if file.new.lineCount > 0, file.new.lineCount <= Self.maxHighlightLines {
                let analysis = Syntax.analyze(file.new.text, language: language)
                set.files[index].newSyntax = SyntaxLines(analysis.spans, text: file.new)
                set.files[index].newSymbols = analysis.symbols
            }
            if file.old.lineCount > 0, file.old.lineCount <= Self.maxHighlightLines {
                let analysis = Syntax.analyze(file.old.text, language: SyntaxLanguage(path: file.oldPath ?? file.path) ?? language)
                set.files[index].oldSyntax = SyntaxLines(analysis.spans, text: file.old)
                set.files[index].oldSymbols = analysis.symbols
            }
        }
        return set
    }

    struct Entry: Equatable, Sendable {
        var status: ChangeStatus
        var path: String
        var oldPath: String?
        var oldMode: String?
        var newMode: String?
        var tracked: Bool
    }

    /// `git diff --raw -z` records: `:<old mode> <new mode> <old sha> <new sha> <status>\0<path>\0`,
    /// a rename or copy with its source path first. Unmerged and unknown entries are skipped.
    static func parseRaw(_ data: Data) -> [Entry] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var entries: [Entry] = []
        var index = 0
        while index < fields.count {
            let meta = fields[index]
            index += 1
            guard meta.hasPrefix(":") else { continue }
            let parts = meta.dropFirst().split(separator: " ")
            guard parts.count >= 5, let letter = parts[4].first else { continue }
            let oldMode = parts[0] == "000000" ? nil : String(parts[0])
            let newMode = parts[1] == "000000" ? nil : String(parts[1])
            let twoPaths = letter == "R" || letter == "C"
            guard index + (twoPaths ? 1 : 0) < fields.count else { break }
            let first = fields[index]
            let second = twoPaths ? fields[index + 1] : nil
            index += twoPaths ? 2 : 1
            switch letter {
            case "A": entries.append(Entry(status: .added, path: first, oldPath: nil, oldMode: nil, newMode: newMode, tracked: true))
            case "D": entries.append(Entry(status: .deleted, path: first, oldPath: nil, oldMode: oldMode, newMode: nil, tracked: true))
            case "M", "T": entries.append(Entry(status: .modified, path: first, oldPath: nil, oldMode: oldMode, newMode: newMode, tracked: true))
            case "R": entries.append(Entry(status: .renamed, path: second ?? first, oldPath: first, oldMode: oldMode, newMode: newMode, tracked: true))
            case "C": entries.append(Entry(status: .added, path: second ?? first, oldPath: nil, oldMode: nil, newMode: newMode, tracked: true))
            default: continue
            }
        }
        return entries
    }

    /// Repository-relative pathspecs for `paths` (board-relative or absolute; none: the board
    /// root). Anything outside the repository is refused: a changes tile never reaches past it.
    public static func pathspecs(_ paths: [String], root: URL, toplevel: URL) throws -> [String] {
        let top = GitDiffEngine.realPath(toplevel).path
        func spec(_ path: String) throws -> String {
            let absolute = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            let real = GitDiffEngine.realPath(absolute.standardizedFileURL).path
            if real == top { return "." }
            guard real.hasPrefix(top + "/") else { throw ChangesFailure("\(path) is outside the repository \(top)") }
            return String(real.dropFirst(top.count + 1))
        }
        return paths.isEmpty ? [try spec(root.path)] : try paths.map(spec)
    }

    /// `-U0` changes per path between the index (`against` nil) or a commit and the working
    /// tree, in working-tree lines.
    static func workingTreeChanges(against commit: String?, paths: [String], in toplevel: URL, runner: GitRunner) async -> [String: [LineRangeMapping]] {
        let args = ["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--diff-algorithm=histogram",
                    "-U0", "--inter-hunk-context=0", "--src-prefix=a/", "--dst-prefix=b/"] + (commit.map { [$0] } ?? []) + ["--"] + paths
        guard let output = try? await runner.run(args, in: toplevel, maxOutput: 64 << 20) else { return [:] }
        return await offPool {
            GitDiffEngine.split(output).mapValues { UnifiedDiff.parse($0).mappings }
        }
    }

    private static func file(_ entry: Entry, base sha: String, diffBase: DiffBase, root: URL, toplevel: URL, engine: GitDiffEngine, runner: GitRunner,
                             unstaged: [LineRangeMapping], head: [LineRangeMapping]?) async -> ChangedFile? {
        let url = toplevel.appendingPathComponent(entry.path)
        let diff: FileDiff
        if entry.status == .renamed, let oldPath = entry.oldPath {
            diff = await renamed(from: oldPath, to: entry.path, base: sha, in: toplevel, engine: engine, runner: runner)
        } else {
            diff = await engine.diff(file: url, base: diffBase)
        }
        var notice: String?
        var status = entry.status
        switch diff.state {
        case .modified: break
        case .added: status = .added
        case .deleted: status = .deleted
        case .unchanged: notice = entry.status == .renamed ? nil : "mode changed"
        case .binary: notice = "binary file"
        case .tooLarge, .diffTooLarge: notice = "too large to show"
        case .submodule: notice = "submodule"
        case .unstable: notice = "kept changing while diffing; waiting for the next write"
        case .missing: return nil
        case .notRepository, .noBase, .pinned, .pinUnavailable: notice = diff.baseLabel ?? "not comparable"
        }
        let newMode = entry.newMode ?? (status == .deleted ? nil : Self.mode(of: url))
        let hunks = notice == nil ? diff.hunks.map { hunk in
            ChangeHunk(mappings: hunk.mappings, old: diff.old, new: diff.new,
                       status: ChangeHunk.status(of: hunk.mappings, tracked: entry.tracked, unstaged: unstaged, head: head))
        } : []
        func boardPath(_ path: String) -> String {
            let absolute = GitDiffEngine.realPath(toplevel.appendingPathComponent(path)).path
            let rootPath = GitDiffEngine.realPath(root).path
            return absolute.hasPrefix(rootPath + "/") ? String(absolute.dropFirst(rootPath.count + 1)) : absolute
        }
        return ChangedFile(path: entry.path, oldPath: entry.oldPath, boardPath: boardPath(entry.path), oldBoardPath: entry.oldPath.map(boardPath),
                           status: status, old: diff.old, new: diff.new, oldMode: status == .added ? nil : entry.oldMode ?? "100644", newMode: newMode,
                           tracked: entry.tracked, hunks: hunks, notice: notice)
    }

    /// A file renamed since the base: `oldPath`'s base text against the working tree's `path`.
    private static func renamed(from oldPath: String, to path: String, base sha: String, in toplevel: URL, engine: GitDiffEngine, runner: GitRunner) async -> FileDiff {
        let url = toplevel.appendingPathComponent(path)
        guard let old = await engine.text(of: toplevel.appendingPathComponent(oldPath), at: sha),
              let data = await offPool({ try? Data(contentsOf: url) }) else {
            return FileDiff(state: .missing, base: sha, baseLabel: nil, old: SideText(""), new: SideText(""), hunks: [])
        }
        let new = await offPool { SideText(String(decoding: data, as: UTF8.self)) }
        let args = ["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M", "--diff-algorithm=histogram",
                    "-U0", "--inter-hunk-context=0", sha, "--", oldPath, path]
        guard let patch = try? await runner.run(args, in: toplevel, maxOutput: 3 * GitDiffEngine.maxFileSize) else {
            return FileDiff(state: .tooLarge, base: sha, baseLabel: nil, old: old, new: new, hunks: [])
        }
        let parsed = await offPool { UnifiedDiff.parse(patch) }
        if parsed.binary { return FileDiff(state: .binary, base: sha, baseLabel: nil, old: old, new: new, hunks: []) }
        let state: FileDiff.State = parsed.mappings.isEmpty ? .unchanged : .modified
        return FileDiff(state: state, base: sha, baseLabel: nil, old: old, new: new, hunks: UnifiedDiff.hunks(parsed.mappings), repository: toplevel.path)
    }

    /// The git mode of a working-tree file: executable or not.
    static func mode(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        return permissions & 0o111 != 0 ? "100755" : "100644"
    }

    // MARK: Summary

    /// What `object.get` adds for a changes tile: the files and their hunks, board-relative.
    public var json: JSONValue {
        var result: [String: JSONValue] = [
            "base": base.map(JSONValue.string) ?? .null,
            "baseLabel": .string(baseLabel),
            "added": .number(Double(added)),
            "removed": .number(Double(removed)),
            "files": .array(files.map(\.json)),
        ]
        if let repository { result["repository"] = .string(repository.path) }
        if let notice { result["notice"] = .string(notice) }
        if omitted > 0 { result["omitted"] = .number(Double(omitted)) }
        return .object(result)
    }
}

extension ChangedFile {
    public var json: JSONValue {
        var result: [String: JSONValue] = [
            "path": .string(boardPath),
            "status": .string(status.rawValue),
            "added": .number(Double(added)),
            "removed": .number(Double(removed)),
            "hunks": .array(hunks.map { hunk in
                .object([
                    "header": .string(hunk.header),
                    "old": .object(["start": .number(Double(hunk.oldStart)), "count": .number(Double(hunk.oldCount))]),
                    "new": .object(["start": .number(Double(hunk.newStart)), "count": .number(Double(hunk.newCount))]),
                    "added": .number(Double(hunk.added)),
                    "removed": .number(Double(hunk.removed)),
                    "status": .string(hunk.status.rawValue),
                ])
            }),
        ]
        if let oldBoardPath { result["oldPath"] = .string(oldBoardPath) }
        if let notice { result["notice"] = .string(notice) }
        return .object(result)
    }
}

public struct ChangesFailure: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}
