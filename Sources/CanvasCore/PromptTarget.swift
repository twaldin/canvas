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

    /// How the tray names the target: its `name`, else the title it shows, else "Terminal".
    public static func label(_ terminal: CanvasObject, shownTitle: String?) -> String {
        func nonEmpty(_ text: String?) -> String? {
            text.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        return nonEmpty(terminal.props["name"]?.string) ?? nonEmpty(shownTitle) ?? nonEmpty(terminal.props["title"]?.string) ?? "Terminal"
    }
}
