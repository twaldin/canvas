import Foundation

/// Who a browser tile's page changes are credited to (`props.url` writes in `board.history`, a
/// tile a page opens): whoever last acted on the page, while that was recent. The user clicking
/// or typing in the page, or using its address bar, back, forward or reload; an agent's driven
/// command (the cmux subset); otherwise the page itself (a redirect, a timer) counts as the
/// app's `system` write-back.
public struct NavigationCredit: Sendable {
    /// How long after an input or command a page change still counts as its result: long enough
    /// for a slow server or a client-side redirect chain, short enough that a page's own timer
    /// much later isn't anyone's doing.
    public static let window: TimeInterval = 10

    private var last: (actor: ActivityActor, at: Date)?

    public init() {}

    /// The user acted on the page.
    public mutating func user(at date: Date = Date()) {
        last = (.user, date)
    }

    /// An agent's command drove the page; `agent` nil when no terminal is known to have sent it.
    public mutating func agent(_ agent: ObjectID?, at date: Date = Date()) {
        last = (agent.map(ActivityActor.agent) ?? .system, date)
    }

    /// The actor a page change at `date` is credited to.
    public func actor(at date: Date = Date()) -> ActivityActor {
        guard let last, date.timeIntervalSince(last.at) <= Self.window else { return .system }
        return last.actor
    }
}
