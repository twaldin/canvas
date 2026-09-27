import Foundation

/// A window's Navigate Back/Forward (⌘[ / ⌘]): each navigation (Go to, a definition, a
/// ⌘-clicked reference, a changes tile's line, Open All, ⌘J, ⌘9, ⌘0, ⇧⌘R's jump, an ⌥⌘-arrow
/// step) records where the view was and where it went, the code tile it re-aimed, if any, and
/// for a step the object selected before and after. Back returns the view to where it was, the
/// tile to what it showed and the step's selection to where it was; Forward goes again. A new
/// navigation after Back drops what Forward would have redone, like a browser. Not an undo
/// step, and undo never moves it.
public struct NavigationHistory: Sendable {
    public struct Entry: Equatable, Sendable {
        public var from: Viewport
        public var to: Viewport
        public var reaim: CodeReaim?
        /// A step's selected object before and after it (nil for other navigations, which leave
        /// the selection alone).
        public var selectedBefore: ObjectID?
        public var selectedAfter: ObjectID?

        public init(from: Viewport, to: Viewport, reaim: CodeReaim?, selectedBefore: ObjectID? = nil, selectedAfter: ObjectID? = nil) {
            self.from = from
            self.to = to
            self.reaim = reaim
            self.selectedBefore = selectedBefore
            self.selectedAfter = selectedAfter
        }
    }

    /// What Back or Forward does: show `viewport`, re-aim `reaim.tile` from `before` to `after`
    /// while it still shows `before` (`Board.restoreAim`), and select `selection` when set.
    public struct Move: Equatable, Sendable {
        public var viewport: Viewport
        public var reaim: CodeReaim?
        public var selection: ObjectID?
    }

    public private(set) var back: [Entry] = []
    public private(set) var forward: [Entry] = []
    public let limit: Int

    public init(limit: Int = 100) {
        self.limit = limit
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Records a navigation. One that neither moved the view, re-aimed a tile nor stepped to
    /// another object is no step.
    public mutating func record(_ entry: Entry) {
        var entry = entry
        if let reaim = entry.reaim, reaim.before == reaim.after { entry.reaim = nil }
        guard entry.reaim != nil || !entry.from.matches(entry.to) || entry.selectedBefore != entry.selectedAfter else { return }
        back.append(entry)
        if back.count > limit { back.removeFirst(back.count - limit) }
        forward.removeAll()
    }

    public mutating func goBack() -> Move? {
        guard let entry = back.popLast() else { return nil }
        forward.append(entry)
        return Move(viewport: entry.from, reaim: entry.reaim?.inverted, selection: entry.selectedBefore)
    }

    public mutating func goForward() -> Move? {
        guard let entry = forward.popLast() else { return nil }
        back.append(entry)
        return Move(viewport: entry.to, reaim: entry.reaim, selection: entry.selectedAfter)
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
