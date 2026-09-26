import Foundation

/// Keeps a follow tile still while the user works in it. Scrolling, clicking, or selecting in
/// the tile holds the agent's re-aims for `hold` seconds after the last interaction; re-aims
/// arriving meanwhile are counted ("N new ▸") and only the newest is kept. When the hold lapses
/// the tile resumes following at that newest aim; catching up shows it at once. The object's
/// props (and so its history strip) record every location regardless: the lock only decides
/// what the tile shows.
public struct FollowLock<Aim: Equatable & Sendable>: Sendable {
    public static var defaultHold: TimeInterval { 10 }

    public let hold: TimeInterval
    /// What the tile shows.
    public private(set) var shown: Aim
    /// The newest aim that arrived while held.
    public private(set) var latest: Aim?
    /// Re-aims that arrived while held.
    public private(set) var missed = 0
    /// When the hold ends; nil when not held.
    public private(set) var until: TimeInterval?

    public init(showing aim: Aim, hold: TimeInterval = defaultHold) {
        shown = aim
        self.hold = hold
    }

    public func isHeld(at now: TimeInterval) -> Bool {
        until.map { now < $0 } ?? false
    }

    /// The user scrolled, clicked, or selected in the tile.
    public mutating func interact(at now: TimeInterval) {
        until = now + hold
    }

    /// The agent re-aimed the tile: the aim to show now, or nil while held (it is queued).
    public mutating func aim(_ aim: Aim, at now: TimeInterval) -> Aim? {
        guard isHeld(at: now) else { return show(aim) }
        if aim != (latest ?? shown) {
            latest = aim
            missed += 1
        }
        return nil
    }

    /// Called when the hold may have lapsed (a timer at `until`): the queued aim to show now.
    public mutating func resume(at now: TimeInterval) -> Aim? {
        guard let until, now >= until else { return nil }
        self.until = nil
        return latest.map { show($0) }
    }

    /// "N new ▸": show the newest queued aim now and end the hold.
    public mutating func catchUp() -> Aim? {
        until = nil
        return latest.map { show($0) }
    }

    /// The user aimed the tile (history strip, go to definition): shown at once; queued agent
    /// aims are dropped, and the hold continues.
    public mutating func userAimed(_ aim: Aim) {
        show(aim)
    }

    @discardableResult
    private mutating func show(_ aim: Aim) -> Aim {
        shown = aim
        latest = nil
        missed = 0
        return aim
    }
}
