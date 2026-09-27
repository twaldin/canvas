import Foundation

/// How the UI names a file (tile titles, tray chips, mentions). Paths under the board root are
/// stored relative and shown as they are. A file outside it, typically in another worktree of
/// the repository, is stored absolute (the API keeps it so), but a truncated
/// `/tmp/canvas-study/repos/trade-up-…/fees/…` says nothing; it shows as
/// `<worktree or repo directory>/<repo-relative path>` instead, the full path in a tooltip.
public enum PathLabel {
    public static func short(_ path: String) -> String {
        guard path.hasPrefix("/"), let worktree = GitWorktree.containing(path),
              let relative = worktree.relativePath(of: path) else { return path }
        return "\(worktree.name)/\(relative)"
    }
}
