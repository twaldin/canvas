import Foundation

/// Who made an object, said quietly on it: an agent's object carries its terminal's name in its
/// title bar (a group, in its title band), so with several agents on one board a note beside one
/// agent's terminal doesn't read as that agent's.
public enum AuthorMark {
    /// The terminal whose agent created `object`, when the object carries its mark. None for the
    /// user's objects, terminals, and follow tiles (each belongs to its terminal, sits beside it,
    /// and says so in its title bar), nor once the author terminal is gone from the board.
    public static func author(of object: CanvasObject, in objects: [ObjectID: CanvasObject]) -> CanvasObject? {
        guard case .agent(let tile) = object.createdBy, object.type != .terminal, object.props["followOf"] == nil,
              let terminal = objects[tile], terminal.type == .terminal else { return nil }
        return terminal
    }

    /// A terminal as an author: its `props.name`, else the program in its foreground
    /// (`TerminalName.program`), else its title (`props.title`, then the agent kind), else
    /// "Terminal". Not the live title a program sets: that changes with every spinner frame.
    public static func name(of terminal: CanvasObject, program: String?) -> String {
        [terminal.props["name"]?.string, program, terminal.props["title"]?.string, terminal.props["agent"]?["kind"]?.string]
            .lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Terminal"
    }

    /// The author's name for `object`'s mark, nil when it carries none; `program` is a
    /// terminal's foreground program, as its tile knows it.
    public static func name(of object: CanvasObject, in objects: [ObjectID: CanvasObject], program: (ObjectID) -> String?) -> String? {
        author(of: object, in: objects).map { name(of: $0, program: program($0.id)) }
    }

    /// The mark's text for an author's name.
    public static func label(_ name: String) -> String { "by \(name)" }

    /// A title bar narrower than this for its title and mark shows no mark.
    public static let minSpace: CGFloat = 160
    /// The share of the space the mark keeps when a long title wants all of it.
    public static let share: CGFloat = 0.35
    /// Between the title and the mark.
    public static let gap: CGFloat = 8

    /// How wide the mark is drawn, from `space` for the title and the mark together, with the
    /// title and the mark `title` and `natural` wide: whole when the title leaves room; beside a
    /// long title, truncated to `share` of the space (the title truncates for the rest); none
    /// under `minSpace`.
    public static func width(natural: CGFloat, title: CGFloat, space: CGFloat) -> CGFloat {
        guard space >= minSpace else { return 0 }
        return min(natural, max(space - title - gap, space * share))
    }
}
