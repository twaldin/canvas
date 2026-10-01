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

    /// `root`, a directory in one checkout, at its place in the other worktree of its repository
    /// that `path` lies in: `/repo/pkg` toward `/wt/pkg/a.swift` is `/wt/pkg`. Nil when `path`
    /// lies in `root`'s own checkout, in another repository, or outside git.
    public static func counterpart(of root: String, toward path: String) -> String? {
        guard let own = containing(root), let other = containing(path), own.commonDir == other.commonDir, own.gitDir != other.gitDir else { return nil }
        return own.relativePath(of: root).map { other.toplevel + "/" + $0 } ?? other.toplevel
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
    public var siblings: [GitWorktree] { Self.worktrees(commonDir: commonDir) }

    /// Every worktree of the repository whose common git directory is `commonDir` (`siblings`).
    public static func worktrees(commonDir: String) -> [GitWorktree] {
        var found: [GitWorktree] = []
        let common = URL(fileURLWithPath: commonDir)
        if common.lastPathComponent == ".git", let main = containing(common.deletingLastPathComponent().path), main.commonDir == commonDir {
            found.append(main)
        }
        let linked = common.appendingPathComponent("worktrees")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: linked.path)) ?? []
        var others: [GitWorktree] = []
        for name in names {
            guard let text = try? String(contentsOf: linked.appendingPathComponent(name).appendingPathComponent("gitdir"), encoding: .utf8) else { continue }
            let dotGit = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
            let top = dotGit.deletingLastPathComponent().path
            guard FileManager.default.fileExists(atPath: dotGit.path), let worktree = containing(top), worktree.commonDir == commonDir,
                  !found.contains(where: { $0.gitDir == worktree.gitDir }) else { continue }
            others.append(worktree)
        }
        return found + others.sorted { $0.name < $1.name }
    }

    /// Whether this is its repository's main checkout (its git directory is the common one;
    /// also a submodule's checkout), not a linked worktree.
    public var isMain: Bool { gitDir == commonDir }

    /// The directory a repository's board is rooted at, whichever worktree opened it: this
    /// checkout when it is the main one, else the repository's main checkout
    /// (`canonicalRoot(commonDir:)`).
    public var canonicalRoot: String { isMain ? toplevel : Self.canonicalRoot(commonDir: commonDir) }

    /// The main checkout of the repository at `commonDir` (a `.git` directory's parent that it
    /// belongs to), else, for a bare repository with linked worktrees (`proj/.bare`), the common
    /// directory's parent.
    public static func canonicalRoot(commonDir: String) -> String {
        let common = URL(fileURLWithPath: commonDir)
        let parent = common.deletingLastPathComponent().path
        if common.lastPathComponent == ".git", let main = containing(parent), main.commonDir == commonDir { return main.toplevel }
        return parent
    }

    /// The repository's local branch names (`refs/heads/**` and `packed-refs`), sorted.
    public static func branches(commonDir: String) -> [String] {
        var names = Set<String>()
        let heads = URL(fileURLWithPath: commonDir).appendingPathComponent("refs/heads")
        if let walker = FileManager.default.enumerator(at: heads, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let path = file.standardizedFileURL.path, base = heads.standardizedFileURL.path + "/"
                if path.hasPrefix(base) { names.insert(String(path.dropFirst(base.count))) }
            }
        }
        for (name, _) in packedRefs(commonDir: commonDir) where name.hasPrefix("refs/heads/") { names.insert(String(name.dropFirst("refs/heads/".count))) }
        return names.sorted()
    }

    /// The commit `refs/heads/<branch>` points at, read from the filesystem; nil when there is no
    /// such branch.
    public static func branchSha(commonDir: String, branch: String) -> String? {
        let file = URL(fileURLWithPath: commonDir).appendingPathComponent("refs/heads").appendingPathComponent(branch)
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let sha = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty, !sha.hasPrefix("ref:") { return sha }
        }
        return packedRefs(commonDir: commonDir).first { $0.name == "refs/heads/" + branch }?.sha
    }

    private static func packedRefs(commonDir: String) -> [(name: String, sha: String)] {
        let text = (try? String(contentsOf: URL(fileURLWithPath: commonDir).appendingPathComponent("packed-refs"), encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#"), !line.hasPrefix("^") else { return nil }
            let parts = line.split(separator: " ", maxSplits: 1)
            return parts.count == 2 ? (String(parts[1]), String(parts[0])) : nil
        }
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

    /// A path in the form `commonDir` is kept in (symlinks resolved), so a worktree reached as
    /// `/tmp/wt` and listed by git as `/private/tmp/wt` is one worktree.
    public static func normalized(_ path: String) -> String { resolved(URL(fileURLWithPath: path)) }
}
