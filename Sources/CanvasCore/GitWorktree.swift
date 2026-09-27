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

    /// The worktree containing `path` (absolute; a file or directory, existing or not), or nil
    /// outside git.
    public static func containing(_ path: String) -> GitWorktree? {
        var directory = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return GitWorktree(toplevel: directory.path, commonDir: resolved(dotGit)) }
                guard let gitDir = linkedGitDir(dotGit) else { return nil }
                return GitWorktree(toplevel: directory.path, commonDir: resolved(commonDir(of: gitDir)))
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
