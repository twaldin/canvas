import Foundation

/// Which agent lifecycle changes deserve a user notification, and whether one decided earlier
/// still describes the agent. Posting is asynchronous (authorization can be pending), so the
/// poster rechecks `isCurrent` right before delivering.
public struct AgentNotices: Sendable {
    public struct Notice: Equatable, Sendable {
        public let tile: ObjectID
        public let blocked: Bool
        public let message: String?
        let generation: Int
    }

    /// Per tile: what was last announced, and the announcement it belongs to.
    private var announced: [ObjectID: (key: String, generation: Int)] = [:]
    private var generation = 0

    public init() {}

    /// A lifecycle change for `tile`; `lifecycle` nil means the agent was released or the tile
    /// deleted. Returns a notice when the tile newly became `done`, `blocked`, or blocked on a
    /// different question; any other change retires the tile's earlier notice.
    public mutating func observe(tile: ObjectID, lifecycle: JSONValue?) -> Notice? {
        let state = lifecycle?["state"]?.string
        guard state == LifecycleState.done.rawValue || state == LifecycleState.blocked.rawValue else {
            announced.removeValue(forKey: tile)
            return nil
        }
        let message = lifecycle?["message"]?.string
        let key = "\(state ?? "")|\(message ?? "")"
        guard announced[tile]?.key != key else { return nil }
        generation += 1
        announced[tile] = (key, generation)
        return Notice(tile: tile, blocked: state == LifecycleState.blocked.rawValue, message: message, generation: generation)
    }

    /// The tile is done or blocked and was announced (its notification, if any, is still valid).
    public func isAnnounced(_ tile: ObjectID) -> Bool {
        announced[tile] != nil
    }

    /// The tile hasn't moved on (worked again, been seen, closed, changed question) since `notice`.
    public func isCurrent(_ notice: Notice) -> Bool {
        announced[notice.tile]?.generation == notice.generation
    }
}
