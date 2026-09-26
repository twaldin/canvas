import Foundation

public enum BoardError: Error, Equatable {
    case notFound(String)
    case conflict(String)
    case invalidParams(String)
}

public enum BoardEvent: Sendable {
    case objectCreated(CanvasObject)
    case objectUpdated(CanvasObject)
    case objectDeleted(ObjectID)
    case trayChanged([Mention])
    case agentLifecycle(tile: ObjectID, lifecycle: JSONValue)
    case followUpdated(tile: ObjectID, follow: ObjectID)

    public var name: String {
        switch self {
        case .objectCreated: "object.created"
        case .objectUpdated: "object.updated"
        case .objectDeleted: "object.deleted"
        case .trayChanged: "tray.changed"
        case .agentLifecycle: "agent.lifecycle"
        case .followUpdated: "follow.updated"
        }
    }

    public var data: JSONValue {
        switch self {
        case .objectCreated(let object), .objectUpdated(let object):
            (try? JSONValue.encode(object)) ?? .null
        case .objectDeleted(let id):
            .object(["id": .string(id)])
        case .trayChanged(let mentions):
            .object(["mentions": (try? JSONValue.encode(mentions)) ?? .array([])])
        case .agentLifecycle(let tile, let lifecycle):
            .object(["tile": .string(tile), "lifecycle": lifecycle])
        case .followUpdated(let tile, let follow):
            .object(["tile": .string(tile), "follow": .string(follow)])
        }
    }
}

/// Serializable board state; what BoardStore persists.
public struct BoardSnapshot: Codable, Sendable {
    public var id: BoardID
    public var root: String
    public var revision: Int
    public var objects: [CanvasObject]
    /// Staged mentions survive quit and rebuild; optional so older board files still load.
    public var tray: [Mention]?
}

/// One canvas: all objects for one root directory, the selection tray, and agent lifecycle.
/// Main-actor only; the socket server and UI both mutate it through these methods.
@MainActor
public final class Board {
    public let id: BoardID
    public let root: URL
    public private(set) var objects: [ObjectID: CanvasObject] = [:]
    public private(set) var revision = 0
    public private(set) var tray: [Mention] = []

    /// Board revision at which each object last changed (for `board.get since`).
    private var changedAt: [ObjectID: Int] = [:]
    /// Terminal tiles the user has seen since their agent last reported `working`.
    private var seenSinceWorking: Set<ObjectID> = []
    /// Highest accepted lifecycle seq per "tile|source".
    private var lifecycleSeq: [String: Int] = [:]
    /// Highest `rev` ever issued per object, kept across deletes so an object brought back by
    /// undo/redo never reuses a revision a stale writer might still hold.
    private var revHighWater: [ObjectID: Int] = [:]

    public var onEvent: ((BoardEvent) -> Void)?
    /// Content changes by anyone, for ⌘Z; see UndoHistory.
    public let history = UndoHistory()
    /// Called after any persisted change; BoardStore debounces saves.
    public var onChange: (() -> Void)?
    /// Viewport center in canvas coordinates, for user-created objects without a frame.
    public var viewportCenter: () -> (x: Double, y: Double) = { (0, 0) }
    /// An arrow's route as currently drawn (canvas coordinates), so deleting what it points at
    /// keeps its end exactly where the user saw it. Without it, routes come from object frames.
    public var arrowRoute: ((ObjectID) -> (start: CGPoint, end: CGPoint)?)?

    public init(id: BoardID, root: URL) {
        self.id = id
        self.root = root
    }

    public init(snapshot: BoardSnapshot) {
        id = snapshot.id
        root = URL(fileURLWithPath: snapshot.root)
        revision = snapshot.revision
        for object in snapshot.objects {
            objects[object.id] = object
            changedAt[object.id] = snapshot.revision
        }
        tray = (snapshot.tray ?? []).filter { $0.target.objectIDs.allSatisfy { objects[$0] != nil } }
    }

    public var snapshot: BoardSnapshot {
        BoardSnapshot(id: id, root: root.path, revision: revision, objects: objects.values.sorted { $0.z < $1.z }, tray: tray)
    }

    public func object(_ id: ObjectID) throws -> CanvasObject {
        guard let object = objects[id] else { throw BoardError.notFound("object \(id)") }
        return object
    }

    public func changed(since cursor: Int) -> [ObjectID] {
        changedAt.filter { $0.value > cursor }.map(\.key).sorted()
    }

    // MARK: Objects

    @discardableResult
    public func create(type: ObjectType, props: JSONValue, frame: Frame? = nil, parent: ObjectID? = nil, caller: ObjectID? = nil) -> CanvasObject {
        let size = Self.defaultSize(type)
        let placed = frame ?? place(width: size.w, height: size.h, near: caller)
        let z = (objects.values.map(\.z).max() ?? 0) + 1
        let object = CanvasObject(id: IDs.make("obj"), type: type, frame: placed, z: z, parent: parent, createdBy: Actor(caller: caller), createdAt: Date(), props: props)
        commit(object)
        history.record(.created(object))
        onEvent?(.objectCreated(object))
        return object
    }

    @discardableResult
    public func update(_ id: ObjectID, rev: Int? = nil, frame: Frame? = nil, z: Double? = nil, props: JSONValue? = nil, caller: ObjectID? = nil) throws -> CanvasObject {
        let before = try object(id)
        if let rev, rev != before.rev { throw BoardError.conflict("object \(id) is at rev \(before.rev), not \(rev)") }
        var object = before
        if let frame { object.frame = frame }
        if let z { object.z = z }
        if let props { object.props = object.props.merging(props) }
        object.rev += 1
        object.updatedAt = Date()
        object.updatedBy = Actor(caller: caller)
        commit(object)
        history.record(.updated(before: before, after: object))
        markMentionsEdited(for: id)
        onEvent?(.objectUpdated(object))
        return object
    }

    public func delete(_ id: ObjectID) throws {
        guard objects[id] != nil else { throw BoardError.notFound("object \(id)") }
        // Arrows bound to it detach within the same undo step, so one ⌘Z restores both.
        history.begin()
        defer { history.end() }
        detachArrows(from: id)
        guard let removed = objects.removeValue(forKey: id) else { throw BoardError.notFound("object \(id)") }
        changedAt.removeValue(forKey: id)
        revision += 1
        history.record(.deleted(removed))
        let before = tray.count
        tray.removeAll { $0.target.objectIDs.contains(id) }
        onChange?()
        onEvent?(.objectDeleted(id))
        if tray.count != before { trayChanged() }
    }

    /// Undo/redo: puts an object state back verbatim (same id and z), announced as a normal change.
    /// The object gets a revision newer than any it has ever had.
    func restore(_ object: CanvasObject) {
        var object = object
        let existed = objects[object.id] != nil
        object.rev = max(revHighWater[object.id] ?? 0, objects[object.id]?.rev ?? 0, object.rev) + 1
        commit(object)
        if existed {
            markMentionsEdited(for: object.id)
            onEvent?(.objectUpdated(object))
        } else {
            onEvent?(.objectCreated(object))
        }
    }

    private func commit(_ object: CanvasObject) {
        revision += 1
        objects[object.id] = object
        changedAt[object.id] = revision
        revHighWater[object.id] = max(revHighWater[object.id] ?? 0, object.rev)
        onChange?()
    }

    public static func defaultSize(_ type: ObjectType) -> (w: Double, h: Double) {
        switch type {
        case .terminal: (820, 520)
        case .browser: (1000, 700)
        case .code: (640, 420)
        case .note: (280, 240)
        case .html: (640, 480)
        case .shape: (160, 100)
        case .arrow, .group: (0, 0)
        }
    }

    /// Next free slot to the right of the caller's tile, stacking downward. Without a caller: the
    /// viewport center, slid right past any tiles it would cover. Drawings never block placement.
    public func place(width: Double, height: Double, near caller: ObjectID?) -> Frame {
        let gap = 24.0
        func blocker(_ frame: Frame) -> CanvasObject? {
            objects.values.first { ![.arrow, .shape, .group].contains($0.type) && $0.frame.intersects(frame) }
        }
        guard let caller, let anchor = objects[caller] else {
            let center = viewportCenter()
            var candidate = Frame(x: center.x - width / 2, y: center.y - height / 2, w: width, h: height)
            while let covered = blocker(candidate) { candidate.x = covered.frame.maxX + gap }
            return candidate
        }
        var candidate = Frame(x: anchor.frame.maxX + gap, y: anchor.frame.y, w: width, h: height)
        while let covered = blocker(candidate) { candidate.y = covered.frame.maxY + gap }
        return candidate
    }

    // MARK: Tray

    @discardableResult
    public func stage(_ target: MentionTarget) throws -> Mention {
        for id in target.objectIDs where objects[id] == nil { throw BoardError.notFound("object \(id)") }
        if let existing = tray.first(where: { $0.target == target }) { return existing }
        let mention = Mention(id: IDs.make("men"), target: target, label: MentionContext.label(for: target, on: self), stagedAt: Date())
        tray.append(mention)
        trayChanged()
        return mention
    }

    public func unstage(_ id: MentionID) throws {
        guard tray.contains(where: { $0.id == id }) else { throw BoardError.notFound("mention \(id)") }
        tray.removeAll { $0.id == id }
        trayChanged()
    }

    /// Resolve every staged mention at its current revision and return the prompt context.
    /// `peek` leaves the tray intact for a later `commit` of exactly these ids.
    /// Old-side and pinned code excerpts are read from git, hence async.
    public func drain(peek: Bool = false) async -> (mentions: [MentionContext.Resolved], context: String) {
        var resolved: [MentionContext.Resolved] = []
        for (index, mention) in tray.enumerated() {
            resolved.append(await MentionContext.resolve(mention, index: index + 1, on: self))
        }
        let context = MentionContext.render(resolved, board: self)
        if !peek { commit(resolved.map(\.id)) }
        return (resolved, context)
    }

    /// Remove exactly these mentions (the ones whose context was delivered). Unknown ids are ignored.
    public func commit(_ ids: [MentionID]) {
        let before = tray.count
        tray.removeAll { ids.contains($0.id) }
        if tray.count != before { trayChanged() }
    }

    private func markMentionsEdited(for id: ObjectID) {
        var changed = false
        for index in tray.indices where tray[index].target.objectIDs.contains(id) && !tray[index].edited {
            tray[index].edited = true
            changed = true
        }
        if changed { trayChanged() }
    }

    private func trayChanged() {
        onChange?()
        onEvent?(.trayChanged(tray))
    }

    // MARK: Agents

    public func reportLifecycle(tile: ObjectID, kind: String, state: LifecycleState, message: String?, seq: Int?, source: String?) throws {
        let terminal = try object(tile)
        guard terminal.type == .terminal else { throw BoardError.invalidParams("\(tile) is not a terminal tile") }
        let key = "\(tile)|\(source ?? kind)"
        if let seq {
            if let last = lifecycleSeq[key], seq <= last { return }
            lifecycleSeq[key] = seq
        }
        if state == .working { seenSinceWorking.remove(tile) }
        let effective: LifecycleState = state == .idle && !seenSinceWorking.contains(tile) && wasWorking(terminal) ? .done : state
        var lifecycle: [String: JSONValue] = ["state": .string(effective.rawValue), "seen": .bool(seenSinceWorking.contains(tile))]
        if let message { lifecycle["message"] = .string(message) }
        let agent = (terminal.props["agent"] ?? .object([:])).merging(.object(["kind": .string(kind)]))
        try update(tile, props: .object(["lifecycle": .object(lifecycle), "agent": agent]), caller: tile)
        onEvent?(.agentLifecycle(tile: tile, lifecycle: .object(lifecycle)))
    }

    private func wasWorking(_ terminal: CanvasObject) -> Bool {
        let state = terminal.props["lifecycle"]?["state"]?.string
        return state == LifecycleState.working.rawValue || state == LifecycleState.done.rawValue
    }

    /// The user has looked at this terminal; a `done` agent becomes `idle`.
    public func markSeen(_ tile: ObjectID) {
        guard let terminal = objects[tile], terminal.type == .terminal, !seenSinceWorking.contains(tile) else { return }
        seenSinceWorking.insert(tile)
        guard terminal.props["lifecycle"]?["state"]?.string == LifecycleState.done.rawValue else { return }
        let lifecycle: JSONValue = .object(["state": .string(LifecycleState.idle.rawValue), "seen": .bool(true)])
        _ = try? update(tile, props: .object(["lifecycle": lifecycle]))
        onEvent?(.agentLifecycle(tile: tile, lifecycle: lifecycle))
    }

    public func reportSession(tile: ObjectID, kind: String, sessionId: String?, sessionPath: String?) throws {
        let terminal = try object(tile)
        var agent = terminal.props["agent"]?.object ?? [:]
        agent["kind"] = .string(kind)
        if let sessionId { agent["sessionId"] = .string(sessionId) }
        if let sessionPath { agent["sessionPath"] = .string(sessionPath) }
        try update(tile, props: .object(["agent": .object(agent)]), caller: tile)
    }

    public func releaseAgent(tile: ObjectID) throws {
        _ = try object(tile)
        try update(tile, props: .object(["lifecycle": .null]), caller: tile)
        onEvent?(.agentLifecycle(tile: tile, lifecycle: .null))
    }

    // MARK: Follow mode

    /// Recent locations kept on a follow tile (`CodeProps.history`), newest first.
    public static let followHistoryLimit = 8

    /// Re-aim the terminal's follow tile at `path`/`range`, creating the tile on first use, and
    /// record the location at the front of the tile's history.
    @discardableResult
    public func follow(tile: ObjectID, path: String, range: LineRange?, action: String) throws -> CanvasObject {
        _ = try object(tile)
        let relative = relativePath(path)
        let rangeValue: JSONValue = range.map { .object(["start": .number(Double($0.start)), "end": .number(Double($0.end))]) } ?? .null
        var props: [String: JSONValue] = ["path": .string(relative), "followOf": .string(tile), "lastAction": .string(action), "range": rangeValue]
        let existing = objects.values.first { $0.type == .code && $0.props["followOf"]?.string == tile }
        var entry: [String: JSONValue] = ["path": .string(relative), "action": .string(action)]
        if range != nil { entry["range"] = rangeValue }
        var history = existing?.props["history"]?.array ?? []
        history.removeAll { $0["path"] == entry["path"] && $0["range"] == entry["range"] }
        history.insert(.object(entry), at: 0)
        props["history"] = .array(Array(history.prefix(Self.followHistoryLimit)))
        let follow: CanvasObject
        if let existing {
            follow = try update(existing.id, props: .object(props), caller: tile)
        } else {
            props["mode"] = .string("diff")
            props["diffBase"] = .string("merge-base")
            follow = create(type: .code, props: .object(props.filter { $0.value != .null }), caller: tile)
        }
        onEvent?(.followUpdated(tile: tile, follow: follow.id))
        return follow
    }

    /// Paths are stored relative to the board root when they live under it.
    public func relativePath(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL.path : root.appendingPathComponent(path).standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return absolute.hasPrefix(rootPath + "/") ? String(absolute.dropFirst(rootPath.count + 1)) : absolute
    }

    public func absoluteURL(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }
}
