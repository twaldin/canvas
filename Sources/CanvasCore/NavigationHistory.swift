import Foundation

/// A window's Navigate Back/Forward (⌘[ / ⌘]): each navigation (Go to, a definition, a
/// ⌘-clicked reference, a changes tile's line, Open All, ⌘J, ⌘9, ⌘0) records where the view was
/// and where it went, and the code tile it re-aimed, if any. Back returns the view to where it
/// was and the tile to what it showed; Forward goes again. A new navigation after Back drops
/// what Forward would have redone, like a browser. Not an undo step, and undo never moves it.
public struct NavigationHistory: Sendable {
    public struct Entry: Equatable, Sendable {
        public var from: Viewport
        public var to: Viewport
        public var reaim: CodeReaim?

        public init(from: Viewport, to: Viewport, reaim: CodeReaim?) {
            self.from = from
            self.to = to
            self.reaim = reaim
        }
    }

    /// What Back or Forward does: show `viewport`, and re-aim `reaim.tile` from `before` to
    /// `after` while it still shows `before` (`Board.restoreAim`).
    public struct Move: Equatable, Sendable {
        public var viewport: Viewport
        public var reaim: CodeReaim?
    }

    public private(set) var back: [Entry] = []
    public private(set) var forward: [Entry] = []
    public let limit: Int

    public init(limit: Int = 100) {
        self.limit = limit
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Records a navigation. One that neither moved the view nor re-aimed a tile is no step.
    public mutating func record(_ entry: Entry) {
        var entry = entry
        if let reaim = entry.reaim, reaim.before == reaim.after { entry.reaim = nil }
        guard entry.reaim != nil || !entry.from.matches(entry.to) else { return }
        back.append(entry)
        if back.count > limit { back.removeFirst(back.count - limit) }
        forward.removeAll()
    }

    public mutating func goBack() -> Move? {
        guard let entry = back.popLast() else { return nil }
        forward.append(entry)
        return Move(viewport: entry.from, reaim: entry.reaim?.inverted)
    }

    public mutating func goForward() -> Move? {
        guard let entry = forward.popLast() else { return nil }
        back.append(entry)
        return Move(viewport: entry.to, reaim: entry.reaim)
    }
}

/// Go to's Recent section: the code locations navigation landed on, most recent first, each
/// file and line once (visiting one again moves it to the top).
public struct RecentLocations: Sendable {
    public private(set) var locations: [CodeAim] = []
    public let limit: Int

    public init(limit: Int = 20) {
        self.limit = limit
    }

    public mutating func visit(_ location: CodeAim) {
        var location = location
        location.symbol = nil
        locations.removeAll { $0.path == location.path && $0.range?.start == location.range?.start }
        locations.insert(location, at: 0)
        if locations.count > limit { locations.removeLast(locations.count - limit) }
    }
}
