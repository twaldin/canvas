import Foundation

/// An agent's "look here" on one object (`view.attention`), kept by the board until the user
/// sees the object or someone clears it. Stored with the board, so unseen markers survive
/// restarts; a marker whose object is deleted goes with it.
public struct Attention: Codable, Equatable, Sendable {
    public var object: ObjectID
    public var message: String?
    /// The agent terminal that raised it (the call's `caller`); nil for a call without one.
    public var raisedBy: ObjectID?
    public var raisedAt: Date
    /// Its agent has started a later turn since (its lifecycle went to `working` from idle, done, or no state), so the
    /// agent's next marker replaces it. Absent while the turn that raised it is current.
    public var earlierTurn: Bool?

    public init(object: ObjectID, message: String?, raisedBy: ObjectID?, raisedAt: Date, earlierTurn: Bool? = nil) {
        self.object = object
        self.message = message
        self.raisedBy = raisedBy
        self.raisedAt = raisedAt
        self.earlierTurn = earlierTurn
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["id": .string(object), "active": .bool(true)]
        if let message { fields["message"] = .string(message) }
        if let raisedBy { fields["raisedBy"] = .string(raisedBy) }
        return .object(fields)
    }
}

extension Board {
    /// Raises (or re-raises, replacing the message) the marker on `id`. A marker belongs to its
    /// agent's turn: raising one clears the markers the same agent raised in earlier turns
    /// (before its lifecycle last went to `working` from idle, done, or no state; blocked → working
    /// continues a turn), returned as `cleared`; markers from the
    /// current turn stay, since one answer may point at several things.
    @discardableResult
    public func raiseAttention(_ id: ObjectID, message: String?, caller: ObjectID?) throws -> (marker: Attention, cleared: [ObjectID]) {
        guard objects[id] != nil else { throw BoardError.notFound("object \(id)") }
        var cleared: [ObjectID] = []
        if let caller {
            for old in attention.values.sorted(by: { $0.object < $1.object }) where old.raisedBy == caller && old.earlierTurn == true && old.object != id {
                clearAttention(old.object)
                cleared.append(old.object)
            }
        }
        let marker = Attention(object: id, message: message, raisedBy: caller, raisedAt: Date())
        attention[id] = marker
        onChange?()
        onEvent?(.attentionChanged(object: id, attention: marker))
        return (marker, cleared)
    }

    /// Removes the marker on `id` (the user saw it, or an agent took it back); false when it had none.
    @discardableResult
    public func clearAttention(_ id: ObjectID) -> Bool {
        guard attention.removeValue(forKey: id) != nil else { return false }
        onChange?()
        onEvent?(.attentionChanged(object: id, attention: nil))
        return true
    }

    /// `tile`'s agent started a new turn: its markers so far belong to earlier turns.
    func agentStartedTurn(_ tile: ObjectID) {
        var changed = false
        for (id, marker) in attention where marker.raisedBy == tile && marker.earlierTurn != true {
            attention[id]?.earlierTurn = true
            changed = true
        }
        if changed { onChange?() }
    }
}
