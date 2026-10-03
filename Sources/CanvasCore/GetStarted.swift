import Foundation

/// Help › Get Started: the guide from a fresh install to a first mention in an agent's prompt.
/// It says what Hyper-click is, the ways to do it, and walks through one on a practice note,
/// step by step: stage a mention, then send it with a prompt.
///
/// It opens by itself at launch until the user closes it once; after that only Help › Get
/// Started opens it. A home that already has boards the first time this is decided belongs to
/// someone who used Easl before the guide existed, and never gets it by itself.
public enum GetStarted {
    /// The practice note's `props.key`, so reopening the guide finds the note it made.
    public static let practiceKey = "canvas.get-started"

    /// The practice note: something to Hyper-click that says what happens next, and reads as a
    /// sensible mention when it reaches the agent.
    public static let practiceMarkdown = """
    # Practice note

    Hyper-click this paragraph: hold ⌃⌥⇧⌘ (Control, Option, Shift and Command) and click it. It becomes a purple chip in the tray at the bottom of the window.

    Then ask your agent something, like "what does this note say?". The chip goes with your prompt, so the agent reads this paragraph without you describing it.
    """

    /// What `get-started.json` records.
    public struct State: Codable, Equatable, Sendable {
        /// The user closed the guide (or had boards before it existed): it no longer opens at launch.
        public var dismissed: Bool

        public init(dismissed: Bool) {
            self.dismissed = dismissed
        }
    }

    /// Whether the guide opens at this launch, and the state to write first (nil: leave the
    /// file as it is). No file yet: a home with boards is an existing user's, recorded as
    /// dismissed; an empty one is a new user's, who gets the guide until they close it.
    public static func atLaunch(saved: State?, hasBoards: Bool) -> (open: Bool, record: State?) {
        if let saved { return (!saved.dismissed, nil) }
        return hasBoards ? (false, State(dismissed: true)) : (true, State(dismissed: false))
    }

    /// The guide's state file in an Easl home (`EASL_HOME`, else Application Support/Easl),
    /// so each development instance has its own. Unreadable counts as absent.
    public struct Store: Sendable {
        public let url: URL

        public init(url: URL) {
            self.url = url
        }

        public func load() -> State? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(State.self, from: data)
        }

        public func save(_ state: State) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        }

        /// The launch decision for this home: opens or not, having written the first state.
        /// `boards` is the home's boards directory (`<boardId>.json` files).
        public func launch(boards: URL) -> Bool {
            let decision = GetStarted.atLaunch(saved: load(), hasBoards: GetStarted.hasBoards(boards))
            if let record = decision.record { try? save(record) }
            return decision.open
        }

        /// Closing the guide: it stops opening at launch.
        public func dismiss() {
            guard load()?.dismissed != true else { return }
            try? save(State(dismissed: true))
        }
    }

    /// A board file in `directory`.
    public static func hasBoards(_ directory: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { $0.hasSuffix(".json") }
    }

    /// Where the walk-through is.
    public enum Step: Equatable, Sendable {
        /// Nothing in the tray. `unstaged`: something was staged and came off again without
        /// being sent (Hyper-clicking a staged thing takes it back off), which the guide says.
        case point(unstaged: Bool)
        /// A mention waits in the tray for the next prompt.
        case send
        /// A mention went to an agent with a prompt (or Hyper-V). Stays done.
        case done
    }

    /// The step, from the tray and what the guide has seen since it opened. A mention already
    /// in the tray when it opens counts as staged.
    public struct Progress: Equatable, Sendable {
        /// `Board.delivered` when the guide opened; more since means a prompt took a mention.
        public let deliveredAtOpen: Int
        public private(set) var staged = false
        public private(set) var step: Step = .point(unstaged: false)

        public init(delivered: Int, trayCount: Int) {
            deliveredAtOpen = delivered
            observe(trayCount: trayCount, delivered: delivered)
        }

        /// Returns true when the step changed.
        @discardableResult
        public mutating func observe(trayCount: Int, delivered: Int) -> Bool {
            let before = step
            if trayCount > 0 { staged = true }
            if step == .done || delivered > deliveredAtOpen {
                step = .done
            } else if trayCount > 0 {
                step = .send
            } else {
                step = .point(unstaged: staged)
            }
            return step != before
        }
    }
}
