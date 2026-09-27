/// The one-screen legend behind Help › Canvas Basics and the tooltips on the things it explains,
/// in the words docs/design.md uses. `skills/canvas/references/ui.md` carries the same text for
/// agents asked "what is this?".
public enum CanvasBasics {
    public struct Item: Sendable {
        /// What it is, as it looks ("Blue dot", "⌘P").
        public var term: String
        public var text: String
    }

    public struct Section: Sendable {
        public var title: String
        public var items: [Item]
    }

    /// What a terminal's lifecycle dot says, for its tooltip; nil without an agent reporting.
    public static func lifecycle(_ state: String?) -> String? {
        switch state {
        case "working": "Working: the agent is busy"
        case "blocked": "Blocked: the agent is waiting for you to approve or answer"
        case "done": "Done: the agent finished and you haven't looked yet"
        case "idle": "Idle: the agent is waiting for your next prompt"
        default: nil
        }
    }

    public static let trayTarget = "Your Hyper-clicked mentions go to this terminal with your next prompt. Click another terminal to send them there."
    public static let followTile = "Follows the file and line this agent last read or edited. Pin keeps the current view as a tile of its own."
    public static let followHistory = "Where the agent has been, newest first; a pencil marks an edit. Click one to show it."
    public static let marker = "An agent (or a program) asks you to look here. Click to go; it clears once you've seen it."
    public static let blockedBubble = "This agent is waiting for you. Click to answer in its terminal."

    public static let sections: [Section] = [
        Section(title: "Reading a board", items: [
            Item(term: "Scroll · pinch", text: "scroll pans, pinch zooms; ⌘9 shows everything, ⌘0 is 100%."),
            Item(term: "Groups and arrows", text: "a tinted, titled region holds tiles that belong together; an arrow's label says how two things relate, and one into a code tile points at its lines."),
            Item(term: "Captions", text: "the line under a code tile's header says why those lines matter."),
            Item(term: "⌥⌘→ · ⌥⌘←", text: "step to the next or previous stop: along the board's next-step arrows when the selected tile has one, else to the nearest tile that way. A stop not in view is centered; \"Last step\" ends the walk."),
            Item(term: "⌘P", text: "find a tile by its title or caption."),
            Item(term: "Links", text: "a path:line link, Go to or ⌘-click goes to the tile already showing those lines, else opens them beside you. Return enters a code tile to scroll it."),
            Item(term: "⌘[ · ⌘]", text: "back and forward through where you went: steps, links, Go to, definitions, ⌘J, Review Changes."),
            Item(term: "Hide Canvas Chrome", text: "View menu, for presenting: hides the toolbar, tray, selection rings, author marks, code headers and agents' markers (a blocked agent still shows). Esc brings them back."),
        ]),
        Section(title: "Agents", items: [
            Item(term: "Blue dot", text: "working: the agent is busy."),
            Item(term: "Orange dot, ring and ✋ bubble", text: "blocked: it waits for you to approve or answer. Click the bubble to answer in its terminal."),
            Item(term: "Green dot", text: "done: it finished and you haven't looked yet."),
            Item(term: "Grey dot", text: "idle: waiting for your next prompt. No dot: no agent reporting."),
            Item(term: "Dot on a board's tab", text: "orange: an agent there is blocked; green: one finished unseen."),
        ]),
        Section(title: "Needs you", items: [
            Item(term: "Pink ring and bubble", text: "an attention marker: an agent (or a bell) says \"look here\". It clears when you select or look at the tile."),
            Item(term: "Pill at the edge", text: "something that needs you is off screen that way. Click it to go there."),
            Item(term: "⌘J", text: "go to the next thing that needs you: blocked agents first, then markers, then agents that finished while you looked elsewhere."),
        ]),
        Section(title: "Agents' tiles", items: [
            Item(term: "Follow tile", text: "each agent's code tile follows the file and line it last read or edited; the strip under it lists recent places (a pencil marks an edit). Pin keeps a view; turn it off with right-click › Follow Files."),
            Item(term: "Where new tiles land", text: "next to the agent's terminal, clear of other tiles, inside your view when there's room nearby. The view never moves by itself: look for a marker, or press ⌘9. \"by name\" in a title bar says which agent made the tile."),
            Item(term: "Undo", text: "⌘Z undoes the last change, yours or an agent's, and says so when it was an agent's; ⇧⌘Z redoes it."),
        ]),
        Section(title: "Pointing your agent at things", items: [
            Item(term: "Hyper-click", text: "⌃⌥⇧⌘-click (Caps Lock as Hyper) a code line, page element, drawing or tile to stage it as a mention in the tray at the bottom."),
            Item(term: "Tray", text: "the chips are staged mentions; \"→ name\" is the terminal they go to with your next prompt. Click a terminal to target it; ⌃⌥⇧⌘V pastes them into one without an integration."),
            Item(term: "Drawing", text: "the toolbar at the top draws boxes (R), ellipses (O), arrows (A), text (T) and ink (P); V selects. Hyper-click a drawing to show the agent what it marks."),
        ]),
        Section(title: "Zoom", items: [
            Item(term: "⌘9 · ⌘0", text: "fit everything · actual size (100%, or the selection at 100%)."),
            Item(term: "⌘= · ⌘-", text: "zoom in and out, 10% to 100%. Zoomed far out, tiles become cards (a picture, tinted by the agent's state); zoom in to use them."),
            Item(term: "⌥-drag a corner", text: "scale a tile to read it from further out."),
        ]),
        Section(title: "Keyboard", items: [
            Item(term: "⌘P", text: "go to a tile, file or symbol."),
            Item(term: "⌘T", text: "new terminal; then run omp, claude, codex, gemini or opencode."),
            Item(term: "Return · Esc", text: "Return enters the selected tile (typing, scrolling code); Esc gives the keyboard back to the canvas. In a terminal Esc goes to the program: ⌘Esc leaves any tile."),
            Item(term: "⌘W · ⌘G", text: "close the selection · group it."),
        ]),
    ]
}
