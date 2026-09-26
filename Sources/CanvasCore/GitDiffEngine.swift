import CryptoKit
import Foundation

/// What a code tile diffs against (`CodeProps.diffBase`).
public enum DiffBase: Hashable, Sendable {
    /// Merge-base of HEAD with the default branch (origin/HEAD, else main, else master).
    case mergeBase
    case head
    case commit(String)

    public init(prop: String?) {
        switch prop {
        case nil, "merge-base": self = .mergeBase
        case "head", "HEAD": self = .head
        case let other?: self = .commit(other)
        }
    }

    /// How mention context names the base: `merge-base`, `HEAD`, or `commit`.
    public var name: String {
        switch self {
        case .mergeBase: "merge-base"
        case .head: "HEAD"
        case .commit: "commit"
        }
    }
}

extension Notification.Name {
    /// Posted (object: the repository's top-level path) when a resolved diff base moved, e.g.
    /// after a commit, checkout, rebase, or fetch. Live code tiles reload on it.
    public static let gitDiffBaseChanged = Notification.Name("canvas.gitDiffBaseChanged")
}

/// Git diffs for code tiles (docs/design.md, Code/diff and Performance):
///  - repositories that live tiles hold (`retain`) keep their resolved diff bases and a debounced
///    FSEvents stream on the git directory that re-resolves them when HEAD or refs move; with no
///    holder the record and its stream are dropped
///  - requests for the same repository and base that arrive together share one `git ls-tree`
///    and one `git diff`
///  - results are cached by (base SHA, content hash), so an unchanged file never runs git
///  - the file is read once, diffed, and read again: a patch that doesn't describe the captured
///    text is retried, never reconstructed
///  - all git goes through `GitRunner.shared` (at most two processes app-wide)
public actor GitDiffEngine {
    public static let shared = GitDiffEngine()

    /// Files larger than this on either side render as a notice instead of a diff.
    public static let maxFileSize = 4 << 20

    /// A base commit and how it was chosen (`merge-base with main`), or no commit and why not
    /// (`no commits yet`, `no default branch`).
    public struct ResolvedBase: Equatable, Sendable {
        public var sha: String?
        public var label: String
    }

    private final class Repository {
        let toplevel: URL
        let watchedDirectories: [String]
        var bases: [DiffBase: ResolvedBase] = [:]
        var watcher: FileEventStream?
        var holders = 0

        init(toplevel: URL, watchedDirectories: [String]) {
            self.toplevel = toplevel
            self.watchedDirectories = watchedDirectories
        }
    }

    private struct CacheKey: Hashable {
        var toplevel: String
        var path: String
        var base: String
        var content: Data
    }

    private struct BatchKey: Hashable {
        var toplevel: String
        var base: String
    }

    /// What `git ls-tree -l` says the base has at a path.
    enum BaseEntry: Equatable, Sendable {
        case absent
        case blob(size: Int)
        case gitlink
        case other
    }

    struct PatchResult: Sendable {
        var patch = Data()
        var entry = BaseEntry.absent
        var tooLarge = false
    }

    private struct Request {
        var path: String
        var continuation: CheckedContinuation<PatchResult, Never>
    }

    private let runner: GitRunner
    private let watchesRepositories: Bool
    /// Held repositories by top-level path, and which directories lie in them.
    private var repositories: [String: Repository] = [:]
    private var repositoryOfDirectory: [String: String] = [:]
    private var cache: [CacheKey: FileDiff] = [:]
    private var cacheOrder: [CacheKey] = []
    private let cacheLimit = 64
    private var batches: [BatchKey: [Request]] = [:]

    public init(runner: GitRunner = .shared, watchesRepositories: Bool = true) {
        self.runner = runner
        self.watchesRepositories = watchesRepositories
    }

    /// Number of `git diff` batches run so far; lets tests observe cache hits.
    public private(set) var diffRuns = 0

    /// Repositories with a live FSEvents stream.
    var watchedRepositoryCount: Int { repositories.values.filter { $0.watcher != nil }.count }

    // MARK: Holding repositories

    /// A live tile showing `file` holds its repository: bases stay resolved and are re-resolved
    /// (with `.gitDiffBaseChanged`) when HEAD or refs move. Returns the top-level path to pass
    /// to `release`, or nil outside git.
    public func retain(containing file: URL) async -> String? {
        guard let repository = await repository(containing: file) else { return nil }
        let key = repository.toplevel.path
        let held = repositories[key] ?? repository
        repositories[key] = held
        repositoryOfDirectory[Self.existingAncestor(of: file.deletingLastPathComponent()).path] = key
        held.holders += 1
        if watchesRepositories, held.watcher == nil { watch(held) }
        return key
    }

    /// Drop one hold; the last one stops the stream and forgets the repository's bases.
    public func release(_ toplevel: String) {
        guard let repository = repositories[toplevel] else { return }
        repository.holders -= 1
        guard repository.holders <= 0 else { return }
        repository.watcher = nil
        repositories.removeValue(forKey: toplevel)
        repositoryOfDirectory = repositoryOfDirectory.filter { $0.value != toplevel }
    }

    // MARK: Diff

    public func diff(file: URL, base: DiffBase) async -> FileDiff {
        for _ in 0..<3 {
            if let diff = await attempt(file: file, base: base) { return diff }
        }
        return FileDiff(state: .unstable, base: nil, baseLabel: nil, old: SideText(""), new: SideText(""), hunks: [])
    }

    /// One read–diff–verify pass; nil when the file changed underneath it.
    private func attempt(file: URL, base: DiffBase) async -> FileDiff? {
        let content = await offPool { Self.read(file) }
        if content.tooLarge { return FileDiff(state: .tooLarge, base: nil, baseLabel: nil, old: SideText(""), new: SideText(""), hunks: []) }
        let data = content.data
        let new = await offPool { SideText(data.map { String(decoding: $0, as: UTF8.self) } ?? "") }
        guard let repository = await repository(containing: file) else {
            let state: FileDiff.State = content.isDirectory ? .missing : data == nil ? .missing : .notRepository
            return FileDiff(state: state, base: nil, baseLabel: nil, old: SideText(""), new: new, hunks: [])
        }
        let toplevel = repository.toplevel.path
        func result(_ state: FileDiff.State, base: String?, label: String?, old: SideText = SideText(""), new: SideText = SideText(""), hunks: [DiffHunk] = []) -> FileDiff {
            FileDiff(state: state, base: base, baseLabel: label, old: old, new: new, hunks: hunks, repository: toplevel)
        }
        if content.isDirectory {
            let isSubmodule = FileManager.default.fileExists(atPath: file.appendingPathComponent(".git").path)
            return result(isSubmodule ? .submodule : .missing, base: nil, label: nil)
        }
        let resolved = await resolve(base, in: repository)
        let binary = data.map(Self.looksBinary) ?? false
        guard let sha = resolved.sha else {
            // No commit to compare with (unborn HEAD, no default branch): plain source.
            if data == nil { return result(.missing, base: nil, label: resolved.label) }
            if binary { return result(.binary, base: nil, label: resolved.label) }
            return result(.noBase, base: nil, label: resolved.label, new: new)
        }
        let path = Self.relative(Self.realPath(file), to: repository.toplevel)
        let hash = await offPool { data.map { Data(SHA256.hash(data: $0)) } ?? Data() }
        let key = CacheKey(toplevel: toplevel, path: path, base: sha, content: hash)
        if let cached = cache[key] { return cached }
        let patch = await patch(path, in: repository, base: sha)
        let patchData = patch.patch
        let parsed = await offPool { UnifiedDiff.parse(patchData) }
        let diff: FileDiff
        if patch.entry == .gitlink || parsed.gitlink {
            diff = result(.submodule, base: sha, label: resolved.label)
        } else if patch.tooLarge {
            // A deleted file's only text is the oversized base; otherwise show the file as source.
            diff = result(data == nil ? .tooLarge : .diffTooLarge, base: sha, label: resolved.label, new: data == nil ? SideText("") : new)
        } else if parsed.binary || binary {
            diff = result(.binary, base: sha, label: resolved.label)
        } else if data == nil {
            guard patch.entry != .absent else { return result(.missing, base: sha, label: resolved.label) }
            // Deleted from the working tree: the patch removes every base line.
            guard let old = await offPool({ UnifiedDiff.reconstructOld(new: new, parsed: parsed) }) else { return nil }
            diff = result(.deleted, base: sha, label: resolved.label, old: old, new: new, hunks: UnifiedDiff.hunks(parsed.mappings))
        } else if patch.entry == .absent {
            diff = result(.added, base: sha, label: resolved.label, new: new, hunks: Self.allAdded(new))
        } else if parsed.mappings.isEmpty {
            // Mode-only changes and identical content alike: nothing to show line by line.
            diff = result(.unchanged, base: sha, label: resolved.label, old: new, new: new)
        } else {
            guard let old = await offPool({ UnifiedDiff.reconstructOld(new: new, parsed: parsed) }) else { return nil }
            diff = result(.modified, base: sha, label: resolved.label, old: old, new: new, hunks: UnifiedDiff.hunks(parsed.mappings))
        }
        // git read the file some time after we did; only a file still identical afterwards
        // proves the patch describes the text we captured.
        guard await offPool({ Self.read(file).data }) == data else { return nil }
        store(diff, for: key)
        return diff
    }

    /// The base a code tile would diff `file` against, resolving it if needed.
    public func resolvedBase(for file: URL, base: DiffBase) async -> ResolvedBase? {
        guard let repository = await repository(containing: file) else { return nil }
        return await resolve(base, in: repository)
    }

    /// `file` as of `commit` (`git cat-file blob`), for excerpts of old-side and pinned lines.
    /// Nil outside git, when the commit lacks the file, or when it is too large.
    public func text(of file: URL, at commit: String) async -> SideText? {
        guard let repository = await repository(containing: file) else { return nil }
        let path = Self.relative(Self.realPath(file), to: repository.toplevel)
        guard let data = try? await runner.run(["cat-file", "blob", "--end-of-options", "\(commit):\(path)"], in: repository.toplevel, maxOutput: Self.maxFileSize) else { return nil }
        return await offPool { SideText(String(decoding: data, as: UTF8.self)) }
    }

    private static func allAdded(_ new: SideText) -> [DiffHunk] {
        new.lineCount == 0 ? [] : [DiffHunk(mappings: [LineRangeMapping(original: 1..<1, modified: 1..<(new.lineCount + 1))])]
    }

    private func store(_ diff: FileDiff, for key: CacheKey) {
        if cache.updateValue(diff, forKey: key) == nil {
            cacheOrder.append(key)
            if cacheOrder.count > cacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        }
    }

    private static func read(_ file: URL) -> (data: Data?, tooLarge: Bool, isDirectory: Bool) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return (nil, false, false) }
        if attributes[.type] as? FileAttributeType == .typeDirectory { return (nil, false, true) }
        if let size = attributes[.size] as? Int, size > maxFileSize { return (nil, true, false) }
        return (try? Data(contentsOf: file), false, false)
    }

    /// git's own heuristic: a NUL byte in the first 8000 bytes.
    private static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    // MARK: Batched git

    private func patch(_ path: String, in repository: Repository, base: String) async -> PatchResult {
        let toplevel = repository.toplevel
        let key = BatchKey(toplevel: toplevel.path, base: base)
        return await withCheckedContinuation { continuation in
            let first = batches[key] == nil
            batches[key, default: []].append(Request(path: path, continuation: continuation))
            // Requests arriving within a short window (tiles going live together) join the same
            // git invocations.
            if first {
                Task {
                    try? await Task.sleep(for: .milliseconds(20))
                    await self.flush(key, toplevel: toplevel)
                }
            }
        }
    }

    private func flush(_ key: BatchKey, toplevel: URL) async {
        guard let requests = batches.removeValue(forKey: key) else { return }
        let paths = Array(Set(requests.map(\.path))).sorted()
        // What the base has at each path, and how big: gitlinks and oversized blobs never reach
        // `git diff`, whose output would otherwise hold the whole removed file.
        var entries: [String: BaseEntry] = [:]
        if let listing = try? await runner.run(["--literal-pathspecs", "ls-tree", "-l", "-z", "--full-tree", key.base, "--"] + paths, in: toplevel) {
            entries = Self.parseTree(listing)
        }
        var results: [String: PatchResult] = [:]
        var diffPaths: [String] = []
        for path in paths {
            let entry = entries[path] ?? .absent
            var result = PatchResult(entry: entry)
            switch entry {
            case .gitlink: break
            case .blob(let size) where size > Self.maxFileSize: result.tooLarge = true
            default: diffPaths.append(path)
            }
            results[path] = result
        }
        if !diffPaths.isEmpty {
            diffRuns += 1
            // -U0 with zero inter-hunk context yields pure change records whatever the user's
            // diff config says; hunks are regrouped locally.
            let args = ["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--diff-algorithm=histogram",
                        "-U0", "--inter-hunk-context=0", "--src-prefix=a/", "--dst-prefix=b/", key.base, "--"] + diffPaths
            do {
                let output = try await runner.run(args, in: toplevel, maxOutput: diffPaths.count * 3 * Self.maxFileSize)
                let sections = await offPool { Self.split(output) }
            for (path, section) in sections where results[path] != nil {
                    results[path]?.patch = section
                }
            } catch GitError.outputTooLarge {
                for path in diffPaths { results[path]?.tooLarge = true }
            } catch {}
        }
        for request in requests {
            request.continuation.resume(returning: results[request.path] ?? PatchResult())
        }
    }

    /// `git ls-tree -l -z` records: `<mode> <type> <object> <size>\t<path>\0`.
    static func parseTree(_ listing: Data) -> [String: BaseEntry] {
        var entries: [String: BaseEntry] = [:]
        for record in listing.split(separator: 0) {
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let meta = String(decoding: record[record.startIndex..<tab], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: true)
            let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
            guard meta.count >= 4 else { continue }
            switch meta[1] {
            case "blob": entries[path] = .blob(size: Int(meta[3]) ?? 0)
            case "commit": entries[path] = .gitlink
            default: entries[path] = .other
            }
        }
        return entries
    }

    /// Per-file sections of a multi-file patch keyed by path, split on LF bytes and with git's
    /// C-quoted names (`"a/tab\there"`) decoded.
    static func split(_ patch: Data) -> [String: Data] {
        var sections: [String: Data] = [:]
        var current: (path: String, start: Int)?
        let bytes = [UInt8](patch)
        let marker = Array("diff --git ".utf8)
        var lineStart = 0
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            if bytes[lineStart..<lineEnd].starts(with: marker) {
                if let current { sections[current.path] = Data(bytes[current.start..<lineStart]) }
                current = headerPath(bytes[(lineStart + marker.count)..<lineEnd]).map { ($0, lineStart) }
            }
            lineStart = lineEnd + 1
        }
        if let current { sections[current.path] = Data(bytes[current.start...]) }
        return sections
    }

    /// The path in `a/<path> b/<path>` (no renames, so both sides name the same file).
    static func headerPath(_ rest: ArraySlice<UInt8>) -> String? {
        if rest.first == UInt8(ascii: "\"") {
            guard let quoted = unquote(rest), quoted.starts(with: Array("a/".utf8)) else { return nil }
            return String(decoding: quoted.dropFirst(2), as: UTF8.self)
        }
        let length = (rest.count - 5) / 2
        guard length > 0, rest.count == 2 * length + 5 else { return nil }
        let path = rest.dropFirst(2).prefix(length)
        guard rest.starts(with: Array("a/".utf8)), Array(rest.suffix(length + 3)) == Array(" b/".utf8) + Array(path) else { return nil }
        return String(decoding: path, as: UTF8.self)
    }

    /// Decodes the leading C-style quoted string git writes for unusual file names.
    static func unquote(_ text: ArraySlice<UInt8>) -> [UInt8]? {
        var out: [UInt8] = []
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let byte = text[index]
            if byte == UInt8(ascii: "\"") { return out }
            guard byte == UInt8(ascii: "\\") else {
                out.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < text.endIndex else { return nil }
            let escaped = text[index]
            switch escaped {
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                guard index + 2 < text.endIndex else { return nil }
                let digits = text[index...(index + 2)].map { Int($0) - 48 }
                guard digits.allSatisfy({ (0...7).contains($0) }) else { return nil }
                out.append(UInt8(truncatingIfNeeded: digits[0] * 64 + digits[1] * 8 + digits[2]))
                index += 3
                continue
            case UInt8(ascii: "a"): out.append(0x07)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "v"): out.append(0x0B)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "r"): out.append(0x0D)
            default: out.append(escaped)
            }
            index += 1
        }
        return nil
    }

    // MARK: Repositories and bases

    /// The held record for the repository containing `file`, or a transient one (bases resolved
    /// afresh each time) when no live tile holds it.
    private func repository(containing file: URL) async -> Repository? {
        let directory = Self.existingAncestor(of: file.deletingLastPathComponent())
        if let known = repositoryOfDirectory[directory.path], let repository = repositories[known] { return repository }
        guard let output = try? await runner.run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"], in: directory) else { return nil }
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count == 3 else { return nil }
        if let held = repositories[lines[0]] {
            repositoryOfDirectory[directory.path] = lines[0]
            return held
        }
        return Repository(toplevel: URL(fileURLWithPath: lines[0]), watchedDirectories: Array(Set([lines[1], lines[2]])))
    }

    private func resolve(_ base: DiffBase, in repository: Repository) async -> ResolvedBase {
        if let known = repository.bases[base] { return known }
        let resolved = await Self.resolve(base, in: repository.toplevel, runner: runner)
        repository.bases[base] = resolved
        return resolved
    }

    static func resolve(_ base: DiffBase, in toplevel: URL, runner: GitRunner) async -> ResolvedBase {
        func verify(_ revision: String) async -> String? {
            guard let data = try? await runner.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(revision)^{commit}"], in: toplevel) else { return nil }
            let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return sha.isEmpty ? nil : sha
        }
        switch base {
        case .head:
            let sha = await verify("HEAD")
            return ResolvedBase(sha: sha, label: sha == nil ? "no commits yet" : "HEAD")
        case .commit(let revision):
            let sha = await verify(revision)
            return ResolvedBase(sha: sha, label: sha == nil ? "unknown commit \(revision)" : revision)
        case .mergeBase:
            guard await verify("HEAD") != nil else { return ResolvedBase(sha: nil, label: "no commits yet") }
            guard let branch = await defaultBranch(in: toplevel, runner: runner) else {
                return ResolvedBase(sha: nil, label: "no default branch")
            }
            let shortName = branch.replacingOccurrences(of: "refs/remotes/", with: "").replacingOccurrences(of: "refs/heads/", with: "")
            let data = try? await runner.run(["merge-base", branch, "HEAD"], in: toplevel)
            let sha = data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            return sha.isEmpty ? ResolvedBase(sha: nil, label: "no merge-base with \(shortName)") : ResolvedBase(sha: sha, label: "merge-base with \(shortName)")
        }
    }

    /// origin/HEAD's target when the clone has one, else local main, else master.
    static func defaultBranch(in toplevel: URL, runner: GitRunner) async -> String? {
        guard let data = try? await runner.run(["for-each-ref", "--format=%(refname)%09%(symref)", "refs/remotes/origin/HEAD", "refs/heads/main", "refs/heads/master"], in: toplevel) else { return nil }
        var refs: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            refs[String(fields[0])] = fields.count > 1 ? String(fields[1]) : ""
        }
        if let target = refs["refs/remotes/origin/HEAD"], !target.isEmpty { return target }
        if refs["refs/heads/main"] != nil { return "refs/heads/main" }
        if refs["refs/heads/master"] != nil { return "refs/heads/master" }
        return nil
    }

    private func watch(_ repository: Repository) {
        let toplevel = repository.toplevel.path
        repository.watcher = FileEventStream(paths: repository.watchedDirectories, latency: 0.4) { [weak self] paths in
            guard let self, paths.contains(where: Self.movesBase) else { return }
            Task { await self.refreshBases(toplevel) }
        }
    }

    /// HEAD, branch refs, and packed-refs decide every base; index, objects, and logs never do.
    nonisolated static func movesBase(_ path: String) -> Bool {
        if path.hasSuffix(".lock") || path.contains("/logs/") || path.contains("/objects/") { return false }
        let name = (path as NSString).lastPathComponent
        return name == "HEAD" || name == "packed-refs" || path.contains("/refs/")
    }

    /// Re-resolve the bases tiles are using; announce the repository when any of them moved.
    func refreshBases(_ toplevel: String) async {
        guard let repository = repositories[toplevel] else { return }
        let previous = repository.bases
        var changed = false
        for base in previous.keys {
            let resolved = await Self.resolve(base, in: repository.toplevel, runner: runner)
            if resolved != previous[base] { changed = true }
            repository.bases[base] = resolved
        }
        if changed {
            NotificationCenter.default.post(name: .gitDiffBaseChanged, object: toplevel)
        }
    }

    // MARK: Paths

    /// Symlink-free absolute path, also for files that no longer exist (deleted in the tree).
    static func realPath(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var existing = standardized
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        // realpath(3), not resolvingSymlinksInPath, which maps /private/var back to /var while git
        // reports the /private form.
        guard let real = realpath(existing.path, nil) else { return standardized }
        defer { free(real) }
        var resolved = URL(fileURLWithPath: String(cString: real))
        for component in missing { resolved.appendPathComponent(component) }
        return resolved
    }

    static func existingAncestor(of directory: URL) -> URL {
        var current = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        while !(FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory) && isDirectory.boolValue), current.path != "/" {
            current.deleteLastPathComponent()
        }
        return current
    }

    static func relative(_ file: URL, to toplevel: URL) -> String {
        let root = toplevel.path.hasSuffix("/") ? toplevel.path : toplevel.path + "/"
        return file.path.hasPrefix(root) ? String(file.path.dropFirst(root.count)) : file.path
    }
}
