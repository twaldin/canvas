/// A changes tile's own keys, which act only while it has the keyboard (Return on the selected
/// tile, or a click in it): j/k (↓/↑) hunks, J/K (]/[) files, Return opens, s stages, u
/// unstages, r asks to discard and ⌘⌫ answers, / filters, m mentions.
public enum ChangesKey: Equatable, Sendable {
    case next, previous, nextFile, previousFile, open, stage, unstage, filter, mention
    /// `r`: asks whether to discard; never discards by itself.
    case askDiscard
    /// ⌘⌫ while the question shows: discards.
    case confirmDiscard

    /// The key a press is: its virtual key code, its characters ignoring modifiers, and whether
    /// ⇧ or ⌘ was held (any other modifier: none of the tile's keys).
    public init?(keyCode: UInt16, characters: String?, shift: Bool, command: Bool, other: Bool) {
        guard !other else { return nil }
        if command {
            guard !shift, keyCode == 51 else { return nil }
            self = .confirmDiscard
            return
        }
        switch (keyCode, characters, shift) {
        case (125, _, false), (_, "j", false): self = .next
        case (126, _, false), (_, "k", false): self = .previous
        case (_, "J", _), (_, "]", false): self = .nextFile
        case (_, "K", _), (_, "[", false): self = .previousFile
        case (36, _, false), (76, _, false): self = .open
        case (_, "s", false): self = .stage
        case (_, "u", false): self = .unstage
        case (_, "r", false): self = .askDiscard
        case (_, "/", false): self = .filter
        case (_, "m", false): self = .mention
        default: return nil
        }
    }
}

/// Discard from the keyboard asks first, and only a key that typing can't produce answers: `r`
/// asks, ⌘⌫ discards while the question shows, and any other key drops the question. Before,
/// a second `r` discarded, so a prompt typed into a changes tile that still had the keyboard
/// (the user thought an agent's terminal had it) threw work away on any word with "rr" in it.
public enum DiscardByKey {
    public enum Step: Equatable, Sendable {
        /// The question shows (again).
        case ask
        /// Discard what the question asked about.
        case discard
        /// The question goes away; the key does what it does.
        case drop
        /// Nothing to do with discarding.
        case none
    }

    /// What `key` (nil: a key that isn't the tile's) does while a Discard question shows
    /// (`asked`) or doesn't.
    public static func step(_ key: ChangesKey?, asked: Bool) -> Step {
        switch key {
        case .askDiscard?: .ask
        case .confirmDiscard?: asked ? .discard : .none
        default: asked ? .drop : .none
        }
    }
}
