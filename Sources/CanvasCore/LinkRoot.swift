import Foundation

/// Link roots: the directory a note's or HTML tile's relative paths resolve against (`path:line`
/// links, markdown links, excerpt fences and images in a note; `<canvas-link>`, `<canvas-code>`
/// and `<img>` in a page). `props.root`, absolute or board-relative, like a changes tile's: the
/// board's own checkout or another worktree of its repository (`checkLinkRoot`); none, the board
/// root. An agent working in another worktree than the board's gets its own checkout as the
/// default (`defaultLinkRoot`), so it writes `tests/x.ts:16`, not `../wt-x/tests/x.ts:16`.
extension Board {
    public func linkRoot(of object: CanvasObject) -> URL { linkRoot(props: object.props) }

    public func linkRoot(props: JSONValue) -> URL {
        guard let value = props["root"]?.string, !value.isEmpty else { return root }
        return absoluteURL(value).standardizedFileURL
    }

    /// A note or HTML tile's `root` must be an existing directory in the board's checkout or in
    /// another worktree of its repository (inside the board root when the board isn't in git).
    public func checkLinkRoot(_ value: String) throws {
        let url = absoluteURL(value).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BoardError.invalidParams("root \(value) is not a directory")
        }
        if GitWorktree.containing(root.path) != nil {
            guard GitWorktree.sameRepository(url.path, root.path) else {
                throw BoardError.invalidParams("root \(value) is not in this board's repository or one of its worktrees")
            }
        } else {
            let base = root.standardizedFileURL.path
            guard url.path == base || url.path.hasPrefix(base + "/") else { throw BoardError.invalidParams("root \(value) is outside the board root") }
        }
    }

    /// The directory a terminal works in: where its shell last reported, else `props.cwd`, else
    /// the board root.
    public func workingDirectory(of terminal: ObjectID) -> String {
        reportedDirectory(terminal) ?? objects[terminal]?.props["cwd"]?.string ?? root.path
    }

    /// The `root` a note or HTML tile gets when `caller` (an agent's terminal) creates it
    /// without one: the caller's checkout when it is another worktree of the board's repository,
    /// at the board root's place in it (a board rooted at `packages/app` maps to `packages/app`
    /// of the worktree). Nil when the caller works in the board's own checkout, or outside it.
    public func defaultLinkRoot(for caller: ObjectID?) -> String? {
        guard let caller, objects[caller]?.type == .terminal,
              let board = GitWorktree.containing(root.path),
              let own = GitWorktree.containing(workingDirectory(of: caller)),
              own.commonDir == board.commonDir, own.gitDir != board.gitDir else { return nil }
        let place = board.relativePath(of: root.path)
        return place.map { URL(fileURLWithPath: own.toplevel).appendingPathComponent($0).path } ?? own.toplevel
    }

    /// `path` (as written in a note or page, or absolute) as the API stores file paths: relative
    /// to the board root when it lies under it, else absolute.
    public func boardPath(_ path: String, linkRoot: URL) -> String {
        relativePath(path.hasPrefix("/") ? path : linkRoot.appendingPathComponent(path).path)
    }
}
