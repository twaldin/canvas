/// Where the keyboard goes when the user turns to something else, so keys always act on what
/// the user is looking at: Return enters a tile, Esc (⌘Esc in a terminal) leaves it, and
/// selecting another tile never leaves the keyboard behind in the one that had it (`s` staging
/// in a changes tile nobody is looking at).
public enum KeyboardFocus {
    /// The tile holding the keyboard (a terminal, a code tile's rows, a changes tile, a note
    /// being edited, a page).
    public struct Holder: Equatable, Sendable {
        public var id: ObjectID
        public var isTerminal: Bool

        public init(_ id: ObjectID, isTerminal: Bool) {
            self.id = id
            self.isTerminal = isTerminal
        }
    }

    public enum Handoff: Equatable, Sendable {
        /// The keyboard stays where it is.
        case stay
        /// The canvas takes it: Delete, Esc, ⌘W and the arrows act on the selection, Return
        /// enters the one selected tile.
        case canvas
        /// This terminal takes it.
        case terminal(ObjectID)
    }

    /// After any change of the selection (a marquee, a drawing or group label pressed, Go to,
    /// a clicked marker): a tile other than a terminal keeps the keyboard only while it is the
    /// whole selection, so the ring and the keys never part. A terminal keeps it: the user
    /// presses drawings and ⌘-clicks references while talking to the agent (dictation pastes
    /// into it).
    public static func afterSelectionChange(_ selection: Set<ObjectID>, holder: Holder?) -> Handoff {
        guard let holder, !holder.isTerminal, selection != [holder.id] else { return .stay }
        return .canvas
    }

    /// A plain press on a tile's title bar (a click, or the start of a drag): the user turned
    /// to that tile. A terminal takes the keyboard (it types when clicked); anything else leaves
    /// it with the canvas, so Return enters it, unless the tile already has it. Whatever had the
    /// keyboard, a terminal included, loses it.
    public static func afterTitleBarPress(on tile: ObjectID, isTerminal: Bool, holder: Holder?) -> Handoff {
        if holder?.id == tile { return .stay }
        return isTerminal ? .terminal(tile) : .canvas
    }

    /// The code tile Code ▸ Go to Definition, Find References and Outline act on: the one with
    /// the keyboard, else the one selected tile, else the tile the user last clicked, when that
    /// is a code tile. Nil when none is (the command says so rather than doing nothing).
    public static func codeTarget(focused: ObjectID?, selection: Set<ObjectID>, lastClicked: ObjectID?, isCode: (ObjectID) -> Bool) -> ObjectID? {
        if let focused, isCode(focused) { return focused }
        if selection.count == 1, let selected = selection.first, isCode(selected) { return selected }
        if let lastClicked, isCode(lastClicked) { return lastClicked }
        return nil
    }
}
