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
///  - one repository record per top-level directory; its diff bases are resolved once and
///    re-resolved when a debounced FSEvents stream on the git directory sees HEAD or refs move
///  - requests for the same repository and base that arrive together share one `git diff`
///  - results are cached by (base SHA, content hash), so an unchanged file never runs git
///  - all git goes through `GitRunner.shared` (at most two processes app-wide)
public actor GitDiffEngine {
    public static let shared = GitDiffEngine()

    /// Larger files render as a notice instead of a diff.
    public static let maxFileSize = 4 << 20

    public struct ResolvedBase: Equatable, Sendable {
        public var sha: String?
        public var label: String
    }

    private final class Repository {
        let toplevel: URL
        let watchedDirectories: [String]
        var bases: [DiffBase: ResolvedBase] = [:]
        var watcher: FileEventStream?

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

    private struct PatchResult: Sendable {
        var patch: Substring
        /// Whether the base has the path; only probed when the patch is empty.
        var inBase: Bool
    }

    private let runner: GitRunner
    private let watchesRepositories: Bool
    private var repositories: [String: Repository] = [:]
    private var repositoryOfDirectory: [String: String] = [:]
    private var cache: [CacheKey: FileDiff] = [:]
    private var cacheOrder: [CacheKey] = []
    private let cacheLimit = 64
    private var batches: [BatchKey: [(path: String, continuation: CheckedContinuation<PatchResult, Never>)]] = [:]

    public init(runner: GitRunner = .shared, watchesRepositories: Bool = true) {
        self.runner = runner
        self.watchesRepositories = watchesRepositories
    }

    /// Number of `git diff` batches run so far; lets tests observe cache hits.
    public private(set) var diffRuns = 0

    // MARK: Diff

    public func diff(file: URL, base: DiffBase) async -> FileDiff {
        let content = Self.read(file)
        let text = content.data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let new = SideText(text)
        if content.tooLarge { return FileDiff(state: .tooLarge, base: nil, baseLabel: nil, old: SideText(""), new: SideText(""), hunks: []) }
        guard let repository = await repository(containing: file) else {
            return FileDiff(state: content.data == nil ? .missing : .notRepository, base: nil, baseLabel: nil, old: SideText(""), new: new, hunks: [])
        }
        let resolved = await resolve(base, in: repository)
        let binary = content.data.map(Self.looksBinary) ?? false
        guard let sha = resolved.sha else {
            // No commit to compare with (unborn HEAD, unknown SHA): the file is all new.
            return Self.allAdded(new, state: content.data == nil ? .missing : binary ? .binary : .added, base: nil, label: resolved.label)
        }
        let path = Self.relative(Self.realPath(file), to: repository.toplevel)
        let key = CacheKey(toplevel: repository.toplevel.path, path: path, base: sha, content: content.data.map { Data(SHA256.hash(data: $0)) } ?? Data())
        if let cached = cache[key] { return cached }
        let result = await patch(path, in: repository, base: sha)
        let parsed = UnifiedDiff.parse(String(result.patch))
        let diff: FileDiff
        if parsed.binary || binary {
            diff = FileDiff(state: .binary, base: sha, baseLabel: resolved.label, old: SideText(""), new: SideText(""), hunks: [])
        } else if parsed.mappings.isEmpty {
            if content.data == nil {
                diff = FileDiff(state: .missing, base: sha, baseLabel: resolved.label, old: SideText(""), new: new, hunks: [])
            } else if result.inBase {
                diff = FileDiff(state: .unchanged, base: sha, baseLabel: resolved.label, old: new, new: new, hunks: [])
            } else {
                diff = Self.allAdded(new, state: .added, base: sha, label: resolved.label)
            }
        } else {
            let old = UnifiedDiff.reconstructOld(new: new, mappings: parsed.mappings, removed: parsed.removed)
            diff = FileDiff(state: content.data == nil ? .deleted : .modified, base: sha, baseLabel: resolved.label, old: old, new: new, hunks: UnifiedDiff.hunks(parsed.mappings))
        }
        store(diff, for: key)
        return diff
    }

    /// The base a code tile would diff `file` against, resolving it if needed.
    public func resolvedBase(for file: URL, base: DiffBase) async -> ResolvedBase? {
        guard let repository = await repository(containing: file) else { return nil }
        return await resolve(base, in: repository)
    }

    private static func allAdded(_ new: SideText, state: FileDiff.State, base: String?, label: String) -> FileDiff {
        let hunks = new.lineCount == 0 || state != .added ? [] : [DiffHunk(mappings: [LineRangeMapping(original: 1..<1, modified: 1..<(new.lineCount + 1))])]
        return FileDiff(state: state, base: base, baseLabel: label, old: SideText(""), new: state == .binary ? SideText("") : new, hunks: hunks)
    }

    private func store(_ diff: FileDiff, for key: CacheKey) {
        if cache.updateValue(diff, forKey: key) == nil {
            cacheOrder.append(key)
            if cacheOrder.count > cacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        }
    }

    private static func read(_ file: URL) -> (data: Data?, tooLarge: Bool) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType != .typeDirectory else { return (nil, false) }
        if let size = attributes[.size] as? Int, size > maxFileSize { return (nil, true) }
        return (try? Data(contentsOf: file), false)
    }

    /// git's own heuristic: a NUL byte in the first 8000 bytes.
    private static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    // MARK: Batched git diff

    private func patch(_ path: String, in repository: Repository, base: String) async -> PatchResult {
        let toplevel = repository.toplevel
        let key = BatchKey(toplevel: toplevel.path, base: base)
        return await withCheckedContinuation { continuation in
            let first = batches[key] == nil
            batches[key, default: []].append((path, continuation))
            // Requests arriving within a short window (tiles going live together) join the same
            // git invocation.
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
        diffRuns += 1
        let output = (try? await runner.run(["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--diff-algorithm=histogram", "-U0", "--src-prefix=a/", "--dst-prefix=b/", key.base, "--"] + paths, in: toplevel)) ?? Data()
        let patches = Self.split(String(decoding: output, as: UTF8.self), paths: paths)
        let unchanged = paths.filter { patches[$0] == nil }
        var inBase = Set<String>()
        if !unchanged.isEmpty, let listed = try? await runner.run(["--literal-pathspecs", "ls-tree", "--full-tree", "--name-only", "-z", key.base, "--"] + unchanged, in: toplevel) {
            inBase = Set(listed.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        }
        for request in requests {
            request.continuation.resume(returning: PatchResult(patch: patches[request.path] ?? "", inBase: inBase.contains(request.path)))
        }
    }

    /// Per-file sections of a multi-file patch, keyed by the requested path.
    static func split(_ patch: String, paths: [String]) -> [String: Substring] {
        let headers = Dictionary(uniqueKeysWithValues: paths.map { ("diff --git a/\($0) b/\($0)", $0) })
        var sections: [String: Substring] = [:]
        var current: (path: String, start: String.Index)?
        var index = patch.startIndex
        while index < patch.endIndex {
            let lineEnd = patch[index...].firstIndex(of: "\n") ?? patch.endIndex
            let line = patch[index..<lineEnd]
            if line.hasPrefix("diff --git ") {
                if let current { sections[current.path] = patch[current.start..<index] }
                current = headers[String(line)].map { ($0, index) }
            }
            index = lineEnd < patch.endIndex ? patch.index(after: lineEnd) : lineEnd
        }
        if let current { sections[current.path] = patch[current.start...] }
        return sections
    }

    // MARK: Repositories and bases

    private func repository(containing file: URL) async -> Repository? {
        let directory = Self.existingAncestor(of: file.deletingLastPathComponent())
        if let known = repositoryOfDirectory[directory.path], let repository = repositories[known] { return repository }
        guard let output = try? await runner.run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"], in: directory) else { return nil }
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count == 3 else { return nil }
        let toplevel = URL(fileURLWithPath: lines[0])
        repositoryOfDirectory[directory.path] = toplevel.path
        if let existing = repositories[toplevel.path] { return existing }
        let repository = Repository(toplevel: toplevel, watchedDirectories: Array(Set([lines[1], lines[2]])))
        repositories[toplevel.path] = repository
        if watchesRepositories { watch(repository) }
        return repository
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
            return ResolvedBase(sha: await verify("HEAD"), label: "HEAD")
        case .commit(let revision):
            return ResolvedBase(sha: await verify(revision), label: revision)
        case .mergeBase:
            guard let branch = await defaultBranch(in: toplevel, runner: runner) else {
                return ResolvedBase(sha: await verify("HEAD"), label: "HEAD (no default branch)")
            }
            let shortName = branch.replacingOccurrences(of: "refs/remotes/", with: "").replacingOccurrences(of: "refs/heads/", with: "")
            guard let data = try? await runner.run(["merge-base", branch, "HEAD"], in: toplevel) else {
                return ResolvedBase(sha: await verify("HEAD"), label: "HEAD (no merge-base with \(shortName))")
            }
            let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return ResolvedBase(sha: sha.isEmpty ? nil : sha, label: "merge-base with \(shortName)")
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
