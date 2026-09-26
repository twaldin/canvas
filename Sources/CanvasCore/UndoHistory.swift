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
        replay {
            for change in step.reversed() {
                switch change {
                case .created(let object): try? delete(object.id)
                case .updated(let before, _): put(before)
                case .deleted(let object): put(object)
                }
            }
        }
        history.pushRedo(step)
        return true
    }

    /// Re-applies the latest undone step. False when there is nothing to redo.
    @discardableResult
    public func redo() -> Bool {
        guard let step = history.popRedo() else { return false }
        replay {
            for change in step {
                switch change {
                case .created(let object): put(object)
                case .updated(_, let after): put(after)
                case .deleted(let object): try? delete(object.id)
                }
            }
        }
        history.pushUndo(step)
        return true
    }

    private func replay(_ body: () -> Void) {
        history.replaying = true
        defer { history.replaying = false }
        body()
    }

    /// Brings an object back to `target`'s content: in place when it exists, else re-created
    /// with the same id and z (undo of a delete).
    private func put(_ target: CanvasObject) {
        var object: CanvasObject
        if let current = objects[target.id] {
            object = UndoHistory.restoring(target, onto: current)
            object.rev = current.rev + 1
        } else {
            object = target
            object.rev = target.rev + 1
        }
        object.updatedAt = Date()
        object.updatedBy = .user
        restore(object)
    }
}
