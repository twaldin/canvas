import Foundation

/// The git working tree a path lies in, found from the filesystem alone (no git process, so
/// it's cheap enough for the main actor): the directory holding `.git`, and the repository's
/// common git directory, which every worktree of one repository shares (what
/// `git rev-parse --git-common-dir` prints). A linked worktree's `.git` is a file naming its
/// private git directory, whose `commondir` file leads back to the shared one.
public struct GitWorktree: Equatable, Sendable {
    /// The working tree's top-level directory, as reached from the path (symlinks unresolved,
    /// so `relativePath(of:)` matches the path it was found from).
    public var toplevel: String
    /// The shared git directory, symlinks resolved.
    public var commonDir: String
    /// The worktree's own git directory (`HEAD`, `index`): `.git` of the main checkout, or
    /// `<common>/worktrees/<name>` of a linked one. Symlinks resolved.
    public var gitDir: String

    /// The worktree containing `path` (absolute; a file or directory, existing or not), or nil
    /// outside git.
    public static func containing(_ path: String) -> GitWorktree? {
        var directory = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    let dir = resolved(dotGit)
                    return GitWorktree(toplevel: directory.path, commonDir: dir, gitDir: dir)
                }
                guard let gitDir = linkedGitDir(dotGit) else { return nil }
                return GitWorktree(toplevel: directory.path, commonDir: resolved(commonDir(of: gitDir)), gitDir: resolved(gitDir))
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }

    /// `path` relative to the top level, or nil when it isn't inside this worktree.
    public func relativePath(of path: String) -> String? {
        let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
        return absolute.hasPrefix(toplevel + "/") ? String(absolute.dropFirst(toplevel.count + 1)) : nil
    }

    /// The worktree's directory name (a linked worktree's, or the main checkout's).
    public var name: String { (toplevel as NSString).lastPathComponent }

    /// Whether two paths lie in worktrees of one repository (the same common git directory).
    public static func sameRepository(_ a: String, _ b: String) -> Bool {
        guard let first = containing(a), let second = containing(b) else { return false }
        return first.commonDir == second.commonDir
    }

    /// The branch checked out (`HEAD`'s `refs/heads/…`), nil when detached.
    public var branch: String? {
        guard let text = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) else { return nil }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        return head.hasPrefix(prefix) ? String(head.dropFirst(prefix.count)) : nil
    }

    /// The repository's default branch as reviews name it, read from the filesystem: origin/HEAD's
    /// target (`origin/main`), else `main`, else `master`, as `GitDiffEngine` picks the branch a
    /// merge-base is taken with; nil when there is none.
    public var defaultBranch: String? {
        let common = URL(fileURLWithPath: commonDir)
        if let text = try? String(contentsOf: common.appendingPathComponent("refs/remotes/origin/HEAD"), encoding: .utf8) {
            let ref = text.trimmingCharacters(in: .whitespacesAndNewlines), prefix = "ref: refs/remotes/"
            if ref.hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
        }
        let packed = ((try? String(contentsOf: common.appendingPathComponent("packed-refs"), encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
        for name in ["main", "master"] {
            if FileManager.default.fileExists(atPath: common.appendingPathComponent("refs/heads/" + name).path) || packed.contains(where: { $0.hasSuffix(" refs/heads/" + name) }) {
                return name
            }
        }
        return nil
    }

    /// Every worktree of this one's repository, the main checkout first, then linked ones by
    /// directory name: the main checkout is the common directory's parent (a non-bare
    /// repository's `.git`), a linked one is named by `worktrees/<name>/gitdir` (its `.git`
    /// file). Worktrees whose directory is gone are left out.
    public var siblings: [GitWorktree] {
        var found: [GitWorktree] = []
        let common = URL(fileURLWithPath: commonDir)
        if common.lastPathComponent == ".git", let main = Self.containing(common.deletingLastPathComponent().path), main.commonDir == commonDir {
            found.append(main)
        }
        let linked = common.appendingPathComponent("worktrees")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: linked.path)) ?? []
        var others: [GitWorktree] = []
        for name in names {
            guard let text = try? String(contentsOf: linked.appendingPathComponent(name).appendingPathComponent("gitdir"), encoding: .utf8) else { continue }
            let dotGit = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
            let top = dotGit.deletingLastPathComponent().path
            guard FileManager.default.fileExists(atPath: dotGit.path), let worktree = Self.containing(top), worktree.commonDir == commonDir,
                  !found.contains(where: { $0.gitDir == worktree.gitDir }) else { continue }
            others.append(worktree)
        }
        return found + others.sorted { $0.name < $1.name }
    }

    /// `gitdir: <path>` in a linked worktree's (or submodule's) `.git` file; a relative path is
    /// relative to the file's directory.
    private static func linkedGitDir(_ file: URL) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return target.hasPrefix("/") ? URL(fileURLWithPath: target) : file.deletingLastPathComponent().appendingPathComponent(target)
    }

    /// A private git directory's `commondir` (relative to it or absolute); without one (a
    /// submodule) the directory is its own common directory.
    private static func commonDir(of gitDir: URL) -> URL {
        guard let text = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) else { return gitDir }
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return gitDir }
        return target.hasPrefix("/") ? URL(fileURLWithPath: target) : gitDir.appendingPathComponent(target)
    }

    private static func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
