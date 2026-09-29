import Foundation

/// Where a branch-anchored tile (`ref`) reads from right now. A ref checked out in a worktree of
/// the repository reads that working tree, live; otherwise the commit it names, from git objects.
/// A ref that no longer resolves (its worktree and branch deleted after a merge) falls back to
/// the last SHA the tile saw: `merged` when the default branch contains it, `missing` when it
/// doesn't (a squash merge, or a branch deleted unmerged), read from objects while they exist.
public enum GitRefs {
    public enum State: Equatable, Sendable {
        /// Checked out in `Resolution.worktree`: read the working tree.
        case live
        /// The ref resolves, but no worktree has it: read git objects at `sha`.
        case objects
        /// The ref is gone and the default branch contains `sha`; the associated SHA is the commit
        /// that brought it in (the merge, or `sha` itself when it was fast-forwarded).
        case merged(String)
        /// The ref is gone and the default branch doesn't contain `sha`.
        case missing
    }

    public struct Resolution: Equatable, Sendable {
        /// The worktree to read when `state` is `.live`, else nil.
        public var worktree: URL?
        /// The commit read: the ref's (or the live worktree's HEAD), else the last known SHA.
        public var sha: String
        public var state: State

        public init(worktree: URL?, sha: String, state: State) {
            self.worktree = worktree
            self.sha = sha
            self.state = state
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case notRevision(String)
        case notRepository
        /// The ref doesn't resolve and no last known SHA whose objects remain was given.
        case unknownRef(String)
    }

    /// Resolves `ref` in the repository of `repo` (any path inside any of its worktrees).
    /// `lastKnownSha` is the SHA a previous resolve returned (a tile's `props.refSha`); it is
    /// what a deleted ref falls back to.
    public static func resolve(repo: URL, ref: String, lastKnownSha: String? = nil, runner: GitRunner = .shared) async throws -> Resolution {
        guard NoteSource.isRevision(ref) else { throw Failure.notRevision(ref) }
        guard let here = GitWorktree.containing(repo.standardizedFileURL.path) else { throw Failure.notRepository }
        let git = URL(fileURLWithPath: here.toplevel)
        if let worktree = liveWorktree(ref, in: here) {
            let top = URL(fileURLWithPath: worktree.toplevel)
            if let sha = await commit("HEAD", in: top, runner: runner) {
                return Resolution(worktree: top, sha: sha, state: .live)
            }
        }
        if let sha = await commit(ref, in: git, runner: runner) {
            return Resolution(worktree: nil, sha: sha, state: .objects)
        }
        guard let last = lastKnownSha, NoteSource.isRevision(last), let sha = await commit(last, in: git, runner: runner) else {
            throw Failure.unknownRef(ref)
        }
        if let merge = await mergeCommit(of: sha, into: here.defaultBranch, in: git, runner: runner) {
            return Resolution(worktree: nil, sha: sha, state: .merged(merge))
        }
        return Resolution(worktree: nil, sha: sha, state: .missing)
    }

    /// The worktree of `checkout`'s repository that has branch `ref` (`name` or `refs/heads/name`)
    /// checked out, from the filesystem alone; nil when none has.
    public static func liveWorktree(_ ref: String, in checkout: GitWorktree) -> GitWorktree? {
        let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        return checkout.siblings.first { $0.branch == branch }
    }

    /// The full SHA of the commit `revision` names, or nil when it names none.
    static func commit(_ revision: String, in directory: URL, runner: GitRunner) async -> String? {
        guard let data = try? await runner.run(["rev-parse", "--verify", "--quiet", "--end-of-options", revision + "^{commit}"], in: directory) else { return nil }
        let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// The commit on `branch`'s first-parent line that brought `sha` in: the earliest one
    /// descending from it (a merge whose side holds `sha`), or `sha` itself when it lies on that
    /// line (fast-forwarded). Nil when `branch` doesn't contain `sha`.
    static func mergeCommit(of sha: String, into branch: String?, in directory: URL, runner: GitRunner) async -> String? {
        guard let branch, let tip = await commit(branch, in: directory, runner: runner),
              (try? await runner.run(["merge-base", "--is-ancestor", sha, tip], in: directory)) != nil else { return nil }
        if sha == tip { return sha }
        guard let data = try? await runner.run(["rev-list", "--first-parent", "--ancestry-path", "--reverse", "--parents", "\(sha)..\(tip)"], in: directory),
              let first = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first else { return nil }
        let shas = first.split(separator: " ").map(String.init)
        guard let commit = shas.first else { return nil }
        // Its first parent is `sha`: `sha` sits on the line itself.
        return shas.dropFirst().first == sha ? sha : commit
    }
}
