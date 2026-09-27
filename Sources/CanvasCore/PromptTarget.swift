import Foundation

/// Which terminal the selection tray drains into (and Superwhisper pastes into): the terminal
/// last focused that runs an agent, else the last focused terminal, else the board's only one.
/// Opening an editor or a plain shell next to an agent never takes the target from the agent.
public enum PromptTarget {
    /// `focusOrder`: terminals in the order they last took keyboard focus, most recent last
    /// (ids no longer on the board are skipped). Nil when no rule applies.
    public static func choose(focusOrder: [ObjectID], objects: [ObjectID: CanvasObject]) -> ObjectID? {
        let focused = focusOrder.reversed().compactMap { id in objects[id].flatMap { $0.type == .terminal ? $0 : nil } }
        if let agent = focused.first(where: runsAgent) { return agent.id }
        if let last = focused.first { return last.id }
        let terminals = objects.values.filter { $0.type == .terminal }
        return terminals.count == 1 ? terminals.first?.id : nil
    }

    /// An agent is running in the terminal: an agent of known kind reports its lifecycle (omp's
    /// extension, the Claude and Codex hooks) and clears it when it exits.
    public static func runsAgent(_ terminal: CanvasObject) -> Bool {
        terminal.props["lifecycle"]?["state"]?.string != nil && terminal.props["agent"]?["kind"]?.string != nil
    }

    /// Worktree affinity: a mention staged from a file in another checkout (a worktree of the
    /// board's repository) than the one the current target works in goes to the agent working
    /// in that checkout, when exactly one agent terminal does (`runsAgent`); otherwise the
    /// target stays. `checkout` is the mention's checkout; `checkouts` the checkout each
    /// terminal works in (its shell's reported directory, else `props.cwd`, else the board
    /// root), keyed by terminal. Checkouts are compared by git directory, so `/tmp` and
    /// `/private/tmp` spellings agree. Returns the terminal to target, or nil to keep the
    /// current one.
    public static func affinity(checkout: GitWorktree, current: ObjectID?, checkouts: [ObjectID: GitWorktree], objects: [ObjectID: CanvasObject]) -> ObjectID? {
        if let current, checkouts[current]?.gitDir == checkout.gitDir { return nil }
        let agents = checkouts.filter { id, worktree in
            worktree.gitDir == checkout.gitDir && objects[id].map { $0.type == .terminal && runsAgent($0) } == true
        }
        guard agents.count == 1, let agent = agents.first?.key, agent != current else { return nil }
        return agent
    }

    /// The checkout a mention's file lies in: a code line's or image pixel's file, or for a
    /// whole object its file (code, image), the worktree a changes tile reviews (`root`), or the
    /// root a note or HTML tile resolves its links against (`root`). Nil for anything else
    /// (pages, terminals, drawings, groups) and outside git.
    @MainActor public static func checkout(of target: MentionTarget, on board: Board) -> GitWorktree? {
        let path: String?
        switch target {
        case .code(_, let file, _, _, _, _, _), .image(_, let file, _, _): path = board.absoluteURL(file).path
        case .object(let id):
            guard let object = board.objects[id] else { return nil }
            switch object.type {
            case .code, .image: path = object.props["path"]?.string.map { board.absoluteURL($0).path }
            case .changes: path = ChangesSpec(object.props).directory(boardRoot: board.root).path
            case .note, .html: path = board.linkRoot(of: object).path
            default: path = nil
            }
        case .note(let id, _): path = board.objects[id].map { board.linkRoot(of: $0).path }
        case .dom, .terminal, .group, .console: path = nil
        }
        return path.flatMap(GitWorktree.containing)
    }

    /// How the tray names the target: its `name`, else the title it shows, else "Terminal".
    public static func label(_ terminal: CanvasObject, shownTitle: String?) -> String {
        func nonEmpty(_ text: String?) -> String? {
            text.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        return nonEmpty(terminal.props["name"]?.string) ?? nonEmpty(shownTitle) ?? nonEmpty(terminal.props["title"]?.string) ?? "Terminal"
    }
}
