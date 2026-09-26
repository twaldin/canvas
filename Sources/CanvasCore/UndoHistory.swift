import Foundation

/// Linear undo/redo of board content changes, whoever made them: ⌘Z undoes the latest change
/// even when an agent made it. Bookkeeping that tracks a terminal rather than content (agent
/// lifecycle, session, title) is never recorded and never rewound.
@MainActor
public final class UndoHistory {
    public enum Change: Sendable {
        case created(CanvasObject)
        case updated(before: CanvasObject, after: CanvasObject)
        case deleted(CanvasObject)
    }

    /// Props a terminal's integrations keep current on their own.
    static let terminalBookkeeping: Set<String> = ["lifecycle", "agent", "title"]

    public private(set) var undoSteps: [[Change]] = []
    public private(set) var redoSteps: [[Change]] = []
    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    public let limit: Int
    private var depth = 0
    private var open: [Change] = []
    /// Set while an undo or redo applies its changes, which must not record themselves.
    var replaying = false

    public init(limit: Int = 200) {
        self.limit = limit
    }

    func record(_ change: Change) {
        guard !replaying else { return }
        if case .updated(let before, let after) = change, Self.content(before) == Self.content(after) { return }
        open.append(change)
        if depth == 0 { close() }
    }

    func begin() {
        depth += 1
    }

    /// Changes recorded so far in the open step.
    var openCount: Int { open.count }

    /// Drops the open step's changes after the first `mark` and returns them, oldest first.
    func discard(from mark: Int) -> [Change] {
        let dropped = Array(open[mark...])
        open.removeSubrange(mark...)
        return dropped
    }

    func end() {
        depth -= 1
        if depth == 0 { close() }
    }

    private func close() {
        guard !open.isEmpty else { return }
        undoSteps.append(open)
        open = []
        if undoSteps.count > limit { undoSteps.removeFirst(undoSteps.count - limit) }
        redoSteps.removeAll()
    }

    func popUndo() -> [Change]? { undoSteps.popLast() }
    func popRedo() -> [Change]? { redoSteps.popLast() }
    func pushRedo(_ step: [Change]) { redoSteps.append(step) }
    func pushUndo(_ step: [Change]) { undoSteps.append(step) }

    /// What an undo compares and restores: everything the user can see change, minus bookkeeping.
    struct Content: Equatable {
        var frame: Frame
        var z: Double
        var parent: ObjectID?
        var props: JSONValue
    }

    static func content(_ object: CanvasObject) -> Content {
        Content(frame: object.frame, z: object.z, parent: object.parent, props: contentProps(object))
    }

    static func contentProps(_ object: CanvasObject) -> JSONValue {
        guard object.type == .terminal, var props = object.props.object else { return object.props }
        for key in terminalBookkeeping { props.removeValue(forKey: key) }
        return .object(props)
    }

    /// `target`'s content applied to `current`, keeping current's bookkeeping props.
    static func restoring(_ target: CanvasObject, onto current: CanvasObject) -> CanvasObject {
        var object = current
        object.frame = target.frame
        object.z = target.z
        object.parent = target.parent
        var props = contentProps(target).object ?? [:]
        if current.type == .terminal, let live = current.props.object {
            for key in terminalBookkeeping { props[key] = live[key] }
        }
        object.props = .object(props)
        return object
    }
}

extension Board {
    /// Groups every change made inside `body` into one undo step (a multi-object gesture).
    public func transaction<T>(_ body: () throws -> T) rethrows -> T {
        history.begin()
        defer { history.end() }
        return try body()
    }

    /// Reverts the latest recorded step. False when there is nothing to undo.
    @discardableResult
    public func undo() -> Bool {
        guard let step = history.popUndo() else { return false }
        history.pushRedo(revert(step))
        return true
    }

    /// Reverts recorded changes, newest first; returns them as a redo step (oldest first).
    @discardableResult
    func revert(_ step: [UndoHistory.Change]) -> [UndoHistory.Change] {
        var replayed: [UndoHistory.Change] = []
        replay {
            for change in step.reversed() {
                switch change {
                case .created(let object):
                    replayed.append(.created(removeLive(object)))
                case .updated(let before, _):
                    put(before)
                    replayed.append(change)
                case .deleted(let object):
                    put(object)
                    replayed.append(change)
                }
            }
        }
        return replayed.reversed()
    }

    /// Re-applies the latest undone step. False when there is nothing to redo.
    @discardableResult
    public func redo() -> Bool {
        guard let step = history.popRedo() else { return false }
        var replayed: [UndoHistory.Change] = []
        replay {
            for change in step {
                switch change {
                case .created(let object):
                    put(object)
                    replayed.append(change)
                case .updated(_, let after):
                    put(after)
                    replayed.append(change)
                case .deleted(let object):
                    replayed.append(.deleted(removeLive(object)))
                }
            }
        }
        history.pushUndo(replayed)
        return true
    }

    /// Deletes an object for undo/redo and returns what to bring back later: the live object,
    /// whose content matches the recorded snapshot (later steps were already reverted) and whose
    /// bookkeeping (agent session, lifecycle, title) is the latest the integrations reported.
    private func removeLive(_ recorded: CanvasObject) -> CanvasObject {
        guard let live = objects[recorded.id] else { return recorded }
        try? delete(recorded.id)
        return live
    }

    private func replay(_ body: () -> Void) {
        history.replaying = true
        defer { history.replaying = false }
        body()
    }

    /// Brings an object back to `target`'s content: in place when it exists, else re-created
    /// with the same id and z (undo of a delete).
    private func put(_ target: CanvasObject) {
        var object = objects[target.id].map { UndoHistory.restoring(target, onto: $0) } ?? target
        object.updatedAt = Date()
        object.updatedBy = .user
        restore(object)
    }
}
