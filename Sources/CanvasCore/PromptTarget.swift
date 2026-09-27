import Foundation

/// Which terminal the selection tray drains into (and Superwhisper pastes into): the terminal
/// the user picked from the tray's menu, until another terminal takes the keyboard; else the
/// last focused terminal running an agent; else the board's only agent terminal; else the last
/// focused terminal; else the board's only one. A plain shell or an editor never takes the
/// target from an agent, unless no agent was ever focused and there are several (or none).
public enum PromptTarget {
    /// What the rule remembers, saved with the board so the target survives a restart.
    public struct State: Codable, Equatable, Sendable {
        /// Terminals in the order they last took keyboard focus (or were made the target by
        /// worktree affinity or the tray's menu), most recent last.
        public var focusOrder: [ObjectID]
        /// The terminal picked from the tray's menu; it stays the target until another terminal
        /// takes the keyboard.
        public var chosen: ObjectID?

        public init(focusOrder: [ObjectID] = [], chosen: ObjectID? = nil) {
            self.focusOrder = focusOrder
            self.chosen = chosen
        }

        /// A terminal took the keyboard (or worktree affinity made it the target).
        public mutating func focused(_ id: ObjectID) {
            focusOrder.removeAll { $0 == id }
            focusOrder.append(id)
            if chosen != id { chosen = nil }
        }

        /// The user picked a terminal from the tray's menu.
        public mutating func choose(_ id: ObjectID) {
            focused(id)
            chosen = id
        }

        /// Forgets terminals no longer on the board.
        public mutating func prune(_ objects: [ObjectID: CanvasObject]) {
            focusOrder.removeAll { objects[$0] == nil }
            if let id = chosen, objects[id] == nil { chosen = nil }
        }
    }

    /// Nil when no rule applies (several terminals, none focused, not exactly one agent).
    public static func choose(_ state: State, objects: [ObjectID: CanvasObject]) -> ObjectID? {
        if let chosen = state.chosen, objects[chosen]?.type == .terminal { return chosen }
        let focused = state.focusOrder.reversed().compactMap { id in objects[id].flatMap { $0.type == .terminal ? $0 : nil } }
        if let agent = focused.first(where: runsAgent) { return agent.id }
        let terminals = objects.values.filter { $0.type == .terminal }
        let agents = terminals.filter(runsAgent)
        if agents.count == 1 { return agents[0].id }
        if let last = focused.first { return last.id }
        return terminals.count == 1 ? terminals.first?.id : nil
    }

    /// The tray menu's terminals: those running an agent first, then the rest, each in reading
    /// order (top to bottom, then left to right).
    public static func menuOrder(_ objects: [ObjectID: CanvasObject]) -> [CanvasObject] {
        objects.values.filter { $0.type == .terminal }.sorted { a, b in
            let agentA = runsAgent(a), agentB = runsAgent(b)
            if agentA != agentB { return agentA }
            if a.frame.y != b.frame.y { return a.frame.y < b.frame.y }
            if a.frame.x != b.frame.x { return a.frame.x < b.frame.x }
            return a.id < b.id
        }
    }

    /// An agent is running in the terminal: an agent of known kind reports its lifecycle (omp's
    /// extension, the Claude and Codex hooks) and clears it when it exits.
    public static func runsAgent(_ terminal: CanvasObject) -> Bool {
        terminal.props["lifecycle"]?["state"]?.string != nil && terminal.props["agent"]?["kind"]?.string != nil
    }

    /// What `agent.prompt` would type into instead of the agent: the terminal's foreground
    /// program (`TerminalStatus.program`) when an agent of `kind` reports there but the program
    /// isn't it (tmux or an editor it runs, a pager): nil when it is the agent (its name is one
    /// of the program's words, ignoring case: `omp`, `codex resume`, `node …/gemini`), and
    /// when either is unknown.
    public static func foreignProgram(kind: String?, program: String?) -> String? {
        guard let kind = kind?.lowercased(), !kind.isEmpty, let program, !program.isEmpty else { return nil }
        let words = program.lowercased().split(separator: " ").map { $0.split(separator: ".").first.map(String.init) ?? String($0) }
        return words.contains(kind) ? nil : program
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
        case .dom, .terminal, .group: path = nil
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
