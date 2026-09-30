import Foundation

/// A changes tile's Discard asks first, by key or by click alike (`ChangesTile`): the first `r`
/// or click on a Discard button asks, and the same again discards, so one stray key (vim's
/// replace) or click never throws work away. The question is one state for the button, which
/// reads "Discard?", and the header's hint saying how to go on, so the two never disagree. It
/// lasts until answered, asked about something else, or dropped (the user did something else),
/// never timing out under its hint: a persona's second click ~3 s after the first only asked
/// again.
public struct DiscardQuestion: Equatable, Sendable {
    /// What a Discard would throw away: a file (`hunk` nil), one of its hunks (by id), or picked
    /// lines of that hunk.
    public struct Target: Equatable, Sendable {
        public var path: String
        public var hunk: String?
        public var lines: Set<Int>?

        public init(path: String, hunk: String?, lines: Set<Int>?) {
            self.path = path
            self.hunk = hunk
            self.lines = lines
        }
    }

    public enum Answer: Equatable, Sendable {
        /// Asked: the button reads "Discard?" and the header shows the hint.
        case asked
        /// Asked again: discard now.
        case confirmed
    }

    /// What is asked about while a question shows.
    public private(set) var target: Target?
    /// The header's hint while a question shows.
    public private(set) var hint: String?

    public init() {}

    /// How a Discard was pressed: its button, `r`, or ⌘⌫ (`DiscardByKey`).
    public enum Input: Equatable, Sendable { case click, key, confirm }

    /// A Discard pressed on `target`: a click or ⌘⌫ on the target of the question showing
    /// confirms it; `r` only ever asks, so a second `r` (typed text: "error", "carry") never
    /// discards; anything else asks about `target`.
    public mutating func press(_ target: Target, by input: Input) -> Answer {
        if input != .key, self.target == target {
            drop()
            return .confirmed
        }
        let what = target.lines.map { "\($0.count) selected line\($0.count == 1 ? "" : "s")" }
            ?? (target.hunk == nil ? "all of \(PathLabel.short(target.path))" : "this hunk")
        self.target = target
        hint = input == .click ? "click Discard again to discard \(what) from your files" : "⌘⌫ discards \(what) from your files · any other key keeps it"
        return .asked
    }

    /// The user moved on (another press or key in the tile, the keyboard left it, something else
    /// was said): no question, no hint.
    public mutating func drop() {
        target = nil
        hint = nil
    }
}
