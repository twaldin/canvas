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
    /// A marker raised or replaced (`attention`), or removed (nil).
    case attentionChanged(object: ObjectID, attention: Attention?)

    public var name: String {
        switch self {
        case .objectCreated: "object.created"
        case .objectUpdated: "object.updated"
        case .objectDeleted: "object.deleted"
        case .trayChanged: "tray.changed"
        case .agentLifecycle: "agent.lifecycle"
        case .followUpdated: "follow.updated"
        case .attentionChanged: "attention.changed"
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
        case .attentionChanged(let id, let attention):
            attention?.json ?? .object(["id": .string(id), "active": .bool(false)])
        }
    }
}

/// Serializable board state; what BoardStore persists.
public struct BoardSnapshot: Codable, Sendable {
    /// On-disk format (`Board.format`); absent in boards saved before tile frames included the
    /// title bar (format 1).
    public var format: Int?
    public var id: BoardID
    public var root: String
    public var revision: Int
    public var objects: [CanvasObject]
    /// Staged mentions survive quit and rebuild; optional so older board files still load.
    public var tray: [Mention]?
    /// Attention markers the user hasn't seen yet; optional so older board files still load.
    public var attention: [Attention]?
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
    /// Unseen attention markers by object (see Attention.swift).
    public internal(set) var attention: [ObjectID: Attention] = [:]

    /// Board revision at which each object last changed (for `board.get since`).
    private var changedAt: [ObjectID: Int] = [:]
    /// Terminal tiles the user has seen since their agent last reported `working`.
    private var seenSinceWorking: Set<ObjectID> = []
    /// Highest accepted lifecycle seq per "tile|source".
    private var lifecycleSeq: [String: Int] = [:]
    /// Highest `rev` ever issued per object, kept across deletes so an object brought back by
    /// undo/redo never reuses a revision a stale writer might still hold.
    private var revHighWater: [ObjectID: Int] = [:]
    /// While an atomic step runs, every change shares this one board revision.
    private var pinnedRevision: Int?

    public var onEvent: ((BoardEvent) -> Void)?
    /// Content changes by anyone, for ⌘Z; see UndoHistory.
    public let history = UndoHistory()
    /// Who did what, for `board.history` (in memory; see ActivityLog).
    public let activity = ActivityLog()
    /// Set while a change's own entry is written by its caller (follow re-aims).
    private var activityMuted = false
    /// "undo"/"redo" while one replays, so its changes are logged as such, credited to `replayActor`.
    var replayVerb: String?
    var replayActor: ActivityActor = .user
    /// Cascade entries logged in `cascadeRevision`, per object: a later cascade on the same
    /// object in the same revision amends that entry (see `log`).
    private var cascades: [ObjectID: (seq: Int, actor: ActivityActor, before: CanvasObject)] = [:]
    private var cascadeRevision = -1
    /// While positive, group re-fits wait in `pendingRefits` for the end of the outermost
    /// `deferringRefits` (see Groups.swift).
    var refitDeferral = 0
    var pendingRefits: [(member: ObjectID, actor: ActivityActor, caller: ObjectID?)] = []
    /// Called after any persisted change; BoardStore debounces saves.
    public var onChange: (() -> Void)?
    /// The canvas rect the board's window shows (canvas coordinates); nil without a window.
    /// Placement prefers slots inside it.
    public var viewport: () -> Frame? = { nil }
    /// An arrow's route as currently drawn (canvas coordinates), so deleting what it points at
    /// keeps its end exactly where the user saw it. Without it, routes come from object frames.
    public var arrowRoute: ((ObjectID) -> (start: CGPoint, end: CGPoint)?)?
    /// Terminal tiles that left the board for good, once the step that removed them is over:
    /// deleted by anyone (API, batch, UI, redo of a delete, undo of a create). A terminal a failed
    /// batch deleted and put back never counts. The app ends their sessions.
    public var onTerminalsEnded: (([ObjectID]) -> Void)?
    /// Terminals deleted in the open step; checked against `objects` when it closes.
    private var removedTerminals: [ObjectID] = []

    public init(id: BoardID, root: URL) {
        self.id = id
        self.root = root
    }

    /// Board format written by `snapshot`. 2: a tile's frame is its whole drawn box, title bar
    /// included (format 1 stored the body below the title bar).
    public static let format = 2

    public init(snapshot: BoardSnapshot) {
        id = snapshot.id
        root = URL(fileURLWithPath: snapshot.root)
        revision = snapshot.revision
        let format = snapshot.format ?? 1
        for var object in snapshot.objects {
            // Groups were labelled by `name` before they became titled regions.
            if object.type == .group, var props = object.props.object, let name = props.removeValue(forKey: "name") {
                if props["title"] == nil { props["title"] = name }
                object.props = .object(props)
            }
            // Format 1 stored a tile's body; the title bar drew above it. Same box on screen.
            if format < 2, RenderMath.isTile(object.type) { object.frame.h += RenderMath.tileTitleHeight }
            objects[object.id] = object
            changedAt[object.id] = snapshot.revision
        }
        // Group frames follow their members (older boards stored placeholders); nested groups
        // settle within a few passes.
        for _ in 0..<8 {
            var changed = false
            for group in objects.values where group.type == .group {
                guard let frame = fittedFrame(ofGroup: group), frame != group.frame else { continue }
                objects[group.id]?.frame = frame
                changed = true
            }
            if !changed { break }
        }
        tray = (snapshot.tray ?? []).filter { $0.target.objectIDs.allSatisfy { objects[$0] != nil } }
        for marker in snapshot.attention ?? [] where objects[marker.object] != nil { attention[marker.object] = marker }
    }

    public var snapshot: BoardSnapshot {
        BoardSnapshot(format: Self.format, id: id, root: root.path, revision: revision, objects: objects.values.sorted { $0.z < $1.z }, tray: tray,
                      attention: attention.isEmpty ? nil : attention.values.sorted { $0.object < $1.object })
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
        let z = (objects.values.map(\.z).max() ?? 0) + 1
        var object = CanvasObject(id: IDs.make("obj"), type: type, frame: frame ?? Frame(x: 0, y: 0, w: size.w, h: size.h), z: z, parent: parent, createdBy: Actor(caller: caller), createdAt: Date(), props: props)
        if let fitted = fittedFrame(ofGroup: object) {
            object.frame = fitted
        } else if frame == nil {
            object.frame = place(width: size.w, height: size.h, near: caller)
        }
        commit(object)
        history.record(.created(object))
        log(.created, object, actor: ActivityActor(caller: caller), "created \(ActivityLog.describe(object)) at \(ActivityLog.position(object.frame))")
        onEvent?(.objectCreated(object))
        return object
    }

    /// Patches an object. A group's frame is never taken from `frame`: it follows its members.
    /// `actor` names who the activity log credits when it isn't the caller (the app's own
    /// write-backs are `.system`).
    @discardableResult
    public func update(_ id: ObjectID, rev: Int? = nil, frame: Frame? = nil, z: Double? = nil, props: JSONValue? = nil, caller: ObjectID? = nil, actor: ActivityActor? = nil) throws -> CanvasObject {
        try write(id, rev: rev, frame: frame, z: z, props: props, caller: caller, actor: actor, refitting: [])
    }

    /// `update`, re-bounding the groups that contain the object in the same undo step.
    /// `refitting` holds the groups already being re-bounded (nested groups, cycles). `cause`
    /// marks a cascade of another change (credited to that change's actor) and says why.
    func write(_ id: ObjectID, rev: Int?, frame: Frame?, z: Double?, props: JSONValue?, caller: ObjectID?, actor: ActivityActor? = nil, cause: String? = nil, refitting: Set<ObjectID>) throws -> CanvasObject {
        let before = try object(id)
        if let rev, rev != before.rev { throw BoardError.conflict("object \(id) is at rev \(before.rev), not \(rev)") }
        var object = before
        if let frame { object.frame = frame }
        if let z { object.z = z }
        if let props { object.props = object.props.merging(props) }
        if let fitted = fittedFrame(ofGroup: object) { object.frame = fitted }
        object.rev += 1
        object.updatedAt = Date()
        object.updatedBy = Actor(caller: caller)
        let credited = actor ?? ActivityActor(caller: caller)
        history.begin()
        defer { endStep() }
        commit(object)
        history.record(.updated(before: before, after: object))
        if let changes = ActivityLog.changes(from: before, to: object) {
            log(.updated, object, actor: credited, "\(ActivityLog.describe(object)): \(changes)", cause: cause, before: before)
        }
        markMentionsEdited(for: id)
        onEvent?(.objectUpdated(object))
        if before.frame != object.frame { refitGroups(containing: id, actor: credited, caller: caller, visited: refitting) }
        return object
    }

    /// Removes an object. Within the same undo step: arrows bound to it detach; a deleted
    /// terminal takes its follow tile with it; a closed follow tile stops its terminal following
    /// (`props.follow` false) so the next report doesn't bring it back. Undo and redo replay
    /// exactly what was recorded.
    public func delete(_ id: ObjectID, caller: ObjectID? = nil) throws {
        guard objects[id] != nil else { throw BoardError.notFound("object \(id)") }
        let actor = ActivityActor(caller: caller)
        // Arrows bound to it detach within the same undo step, so one ⌘Z restores both.
        history.begin()
        defer { endStep() }
        detachArrows(from: id, actor: actor, caller: caller)
        guard let removed = objects.removeValue(forKey: id) else { throw BoardError.notFound("object \(id)") }
        changedAt.removeValue(forKey: id)
        bumpRevision()
        history.record(.deleted(removed))
        if removed.type == .terminal { removedTerminals.append(id) }
        log(.deleted, removed, actor: actor, "deleted \(ActivityLog.describe(removed))")
        let before = tray.count
        tray.removeAll { $0.target.objectIDs.contains(id) }
        let marked = attention.removeValue(forKey: id) != nil
        onChange?()
        onEvent?(.objectDeleted(id))
        if tray.count != before { trayChanged() }
        if marked { onEvent?(.attentionChanged(object: id, attention: nil)) }
        refitGroups(containing: id, actor: actor, caller: caller)
        guard !history.replaying else { return }
        if removed.type == .terminal {
            for follow in followTiles(of: id) { try delete(follow.id, caller: caller) }
        } else if let terminal = removed.props["followOf"]?.string.flatMap({ objects[$0] }), terminal.props["follow"]?.bool != false {
            _ = try write(terminal.id, rev: nil, frame: nil, z: nil, props: .object(["follow": .bool(false)]), caller: caller, actor: actor,
                          cause: "its follow tile was closed", refitting: [])
        }
    }

    /// Logs a change. A cascade (`cause` set, with the object's state `before` it) that hits an
    /// object already cascaded in this revision by the same actor amends that entry to the net
    /// change, or drops it when the changes cancel out: one entry per group per batch, however
    /// many of its members the batch moved or deleted.
    private func log(_ kind: ActivityEntry.Kind, _ object: CanvasObject, actor: ActivityActor, _ summary: String, cause: String? = nil, before: CanvasObject? = nil) {
        guard !activityMuted else { return }
        guard replayVerb == nil else {
            activity.record(kind, actor: replayActor, rev: revision, id: object.id, type: object.type, summary: "\(replayVerb!): \(summary)")
            return
        }
        guard let cause, let before, kind == .updated else {
            activity.record(kind, actor: actor, rev: revision, id: object.id, type: object.type, summary: summary)
            return
        }
        if cascadeRevision != revision {
            cascades = [:]
            cascadeRevision = revision
        }
        var first = before
        if let earlier = cascades[object.id], earlier.actor == actor {
            guard let changes = ActivityLog.changes(from: earlier.before, to: object) else {
                activity.remove(seq: earlier.seq)
                cascades.removeValue(forKey: object.id)
                return
            }
            if activity.amend(seq: earlier.seq, summary: "\(ActivityLog.describe(object)): \(changes)") { return }
            first = earlier.before
        }
        activity.record(kind, actor: actor, rev: revision, id: object.id, type: object.type, summary: summary, cause: cause)
        cascades[object.id] = (activity.cursor, actor, first)
    }

    /// Undo/redo: puts an object state back verbatim (same id and z), announced as a normal change.
    /// The object gets a revision newer than any it has ever had.
    func restore(_ object: CanvasObject) {
        var object = object
        let previous = objects[object.id]
        object.rev = max(revHighWater[object.id] ?? 0, objects[object.id]?.rev ?? 0, object.rev) + 1
        commit(object)
        if let previous {
            if let changes = ActivityLog.changes(from: previous, to: object) {
                log(.updated, object, actor: replayActor, "\(ActivityLog.describe(object)): \(changes)")
            }
            markMentionsEdited(for: object.id)
            onEvent?(.objectUpdated(object))
        } else {
            log(.created, object, actor: replayActor, "restored \(ActivityLog.describe(object)) at \(ActivityLog.position(object.frame))")
            onEvent?(.objectCreated(object))
        }
    }

    private func commit(_ object: CanvasObject) {
        bumpRevision()
        objects[object.id] = object
        changedAt[object.id] = revision
        revHighWater[object.id] = max(revHighWater[object.id] ?? 0, object.rev)
        onChange?()
    }

    private func bumpRevision() {
        revision = pinnedRevision ?? revision + 1
    }

    /// Closes a step opened with `history.begin()`. When the outermost one closes, terminals it
    /// deleted that are still gone (a failed batch puts its deletes back) are reported ended.
    func endStep() {
        history.end()
        guard !history.isOpen, !removedTerminals.isEmpty else { return }
        let ended = removedTerminals.filter { objects[$0] == nil }
        removedTerminals = []
        if !ended.isEmpty { onTerminalsEnded?(ended) }
    }

    /// Runs `body` as one undo step and one board revision; when it throws, every change it
    /// made is reverted (announced as normal changes) and the error rethrown.
    public func atomically<T>(_ body: () throws -> T) throws -> T {
        let outermost = pinnedRevision == nil
        if outermost { pinnedRevision = revision + 1 }
        history.begin()
        let mark = history.mark()
        defer {
            endStep()
            if outermost { pinnedRevision = nil }
        }
        do {
            return try body()
        } catch {
            replayVerb = "reverted (batch failed)"
            replayActor = .system
            defer {
                replayVerb = nil
                replayActor = .user
            }
            revert(history.discard(from: mark))
            throw error
        }
    }

    /// Frame size a new object gets without one; a tile's includes its title bar.
    public static func defaultSize(_ type: ObjectType) -> (w: Double, h: Double) {
        switch type {
        case .terminal: (1000, 620)
        case .browser: (1000, 726)
        case .code: (640, 446)
        case .note: (280, 266)
        case .html: (640, 506)
        case .shape: (160, 100)
        case .arrow, .group: (0, 0)
        }
    }

    /// Room kept between a placed object and its neighbours.
    public static let placementGap = 24.0

    /// Where a new object goes when nobody gave it a frame: the free slot nearest the caller's
    /// tile, touching it at `placementGap` when there's room (right first, then below, left,
    /// above), else nearest the viewport center. See `place(_:)` for what counts as free.
    public func place(width: Double, height: Double, near caller: ObjectID?) -> Frame {
        if let caller, let anchor = objects[caller] { return freeSlot(width: width, height: height, anchor: anchor.frame, beside: true) }
        let view = viewport() ?? Frame(x: 0, y: 0, w: 0, h: 0)
        return place(Frame(x: view.x + view.w / 2 - width / 2, y: view.y + view.h / 2 - height / 2, w: width, h: height))
    }

    /// The free slot nearest `ideal` (a frame of the object's size, e.g. at a click point). A slot
    /// is free when it keeps `placementGap` from every object but drawings and arrows (other
    /// agents' tiles and groups included). While the ideal spot (or the caller's tile) is on
    /// screen, slots wholly inside the viewport win over nearer ones outside it. Origins are whole
    /// points.
    public func place(_ ideal: Frame) -> Frame {
        freeSlot(width: ideal.w, height: ideal.h, anchor: ideal, beside: false)
    }

    /// `beside`: the slot goes next to `anchor` (an object), nearest by the gap between them;
    /// otherwise it replaces `anchor`, nearest by origin.
    private func freeSlot(width w: Double, height h: Double, anchor: Frame, beside: Bool) -> Frame {
        let gap = Self.placementGap
        let blocked = objects.values.filter { $0.type != .arrow && $0.type != .shape }
            .map { Frame(x: $0.frame.x - gap, y: $0.frame.y - gap, w: $0.frame.w + 2 * gap, h: $0.frame.h + 2 * gap) }
        let screen = viewport().flatMap { view in
            view.intersects(anchor) && view.w > 2 * gap && view.h > 2 * gap ? Frame(x: view.x + gap, y: view.y + gap, w: view.w - 2 * gap, h: view.h - 2 * gap) : nil
        }
        // Edges a best slot can rest against: the anchor's, each blocker's, and the viewport's.
        var xs: Set<Double> = [anchor.x.rounded(), (anchor.maxX - w).rounded()]
        var ys: Set<Double> = [anchor.y.rounded(), (anchor.maxY - h).rounded()]
        for frame in blocked {
            xs.formUnion([frame.maxX.rounded(.up), (frame.x - w).rounded(.down)])
            ys.formUnion([frame.maxY.rounded(.up), (frame.y - h).rounded(.down)])
        }
        if let screen {
            xs.formUnion([screen.x.rounded(.up), (screen.maxX - w).rounded(.down)])
            ys.formUnion([screen.y.rounded(.up), (screen.maxY - h).rounded(.down)])
        }
        // Offscreen, then distance to the anchor, then side (right, below, left, above), then
        // distance from where that side's slot would ideally start; ties go top-left first.
        typealias Cost = (Int, Double, Int, Double, Double, Double)
        func cost(_ slot: Frame) -> Cost {
            let outside = screen.map { $0.contains(slot) ? 0 : 1 } ?? 0
            guard beside else { return (outside, 0, 0, hypot(slot.x - anchor.x, slot.y - anchor.y), slot.y, slot.x) }
            let dx = max(0, anchor.x - slot.maxX, slot.x - anchor.maxX)
            let dy = max(0, anchor.y - slot.maxY, slot.y - anchor.maxY)
            let side: Int
            let ideal: (x: Double, y: Double)
            if slot.x >= anchor.maxX {
                (side, ideal) = (0, (anchor.maxX + gap, anchor.y))
            } else if slot.y >= anchor.maxY {
                (side, ideal) = (1, (anchor.x, anchor.maxY + gap))
            } else if slot.maxX <= anchor.x {
                (side, ideal) = (2, (anchor.x - w - gap, anchor.y))
            } else {
                (side, ideal) = (3, (anchor.x, anchor.y - h - gap))
            }
            return (outside, hypot(dx, dy).rounded(), side, hypot(slot.x - ideal.x, slot.y - ideal.y), slot.y, slot.x)
        }
        var best: (slot: Frame, cost: Cost)?
        for x in xs {
            for y in ys {
                let slot = Frame(x: x, y: y, w: w, h: h)
                let slotCost = cost(slot)
                if let best, !(slotCost < best.cost) { continue }
                if blocked.contains(where: { $0.intersects(slot) }) { continue }
                best = (slot, slotCost)
            }
        }
        // Unreachable: right of the rightmost blocker is always free.
        return best?.slot ?? Frame(x: anchor.x.rounded(), y: anchor.y.rounded(), w: w, h: h)
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
        if state == .working {
            seenSinceWorking.remove(tile)
            // Going to working from idle, done, or no state is the user's next prompt reaching the
            // agent: a new turn. From blocked (an approval answered) it continues the same answer.
            let previous = terminal.props["lifecycle"]?["state"]?.string
            if previous != LifecycleState.working.rawValue, previous != LifecycleState.blocked.rawValue { agentStartedTurn(tile) }
        }
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
    /// record the location at the front of the tile's history. Ignored (returns nil) while the
    /// terminal doesn't follow (`props.follow` false) and for files `FollowFilter` rejects:
    /// outside the board root and the terminal's cwd, scratch files in the temp directory,
    /// missing files, images, and other binaries. The tile keeps its last real file.
    @discardableResult
    public func follow(tile: ObjectID, path: String, range: LineRange?, action: String) throws -> CanvasObject? {
        let terminal = try object(tile)
        guard terminal.props["follow"]?.bool != false else { return nil }
        let projects = [root.path] + [terminal.props["cwd"]?.string].compactMap { $0 }
        guard FollowFilter.follows(absoluteURL(path).path, projects: projects) else { return nil }
        let relative = relativePath(path)
        let rangeValue: JSONValue = range.map { .object(["start": .number(Double($0.start)), "end": .number(Double($0.end))]) } ?? .null
        var props: [String: JSONValue] = ["path": .string(relative), "followOf": .string(tile), "lastAction": .string(action), "range": rangeValue]
        let existing = followTiles(of: tile).first
        var entry: [String: JSONValue] = ["path": .string(relative), "action": .string(action)]
        if range != nil { entry["range"] = rangeValue }
        var history = existing?.props["history"]?.array ?? []
        history.removeAll { $0["path"] == entry["path"] && $0["range"] == entry["range"] }
        history.insert(.object(entry), at: 0)
        props["history"] = .array(Array(history.prefix(Self.followHistoryLimit)))
        let follow: CanvasObject
        activityMuted = true
        defer { activityMuted = false }
        if let existing {
            follow = try update(existing.id, props: .object(props), caller: tile)
        } else {
            props["diffBase"] = .string("merge-base")
            follow = create(type: .code, props: .object(props.filter { $0.value != .null }), caller: tile)
        }
        activityMuted = false
        let at = range.map { ":\($0.start)-\($0.end)" } ?? ""
        activity.record(.follow, actor: .agent(tile), rev: revision, id: follow.id, type: .code,
                        summary: "\(existing == nil ? "follow tile created" : "follow tile re-aimed") at \(relative)\(at) (\(action))")
        onEvent?(.followUpdated(tile: tile, follow: follow.id))
        return follow
    }

    /// The code tiles following `terminal` (one, unless an undo or a copy made more).
    public func followTiles(of terminal: ObjectID) -> [CanvasObject] {
        objects.values.filter { $0.type == .code && $0.props["followOf"]?.string == terminal }
    }

    /// Turns a terminal's follow mode on (the next report creates its tile) or off (its follow
    /// tile goes), in one undo step.
    public func setFollowing(_ tile: ObjectID, _ on: Bool, caller: ObjectID? = nil) throws {
        guard try object(tile).type == .terminal else { throw BoardError.invalidParams("\(tile) is not a terminal tile") }
        try atomically {
            try update(tile, props: .object(["follow": .bool(on)]), caller: caller)
            if !on { for follow in followTiles(of: tile) { try delete(follow.id, caller: caller) } }
        }
    }

    /// Keep what a follow tile shows (`path`/`range`, which a user holding the tile may keep
    /// behind its props) as a permanent code tile beside it, with the same diff base.
    @discardableResult
    public func pin(_ follow: ObjectID, path: String, range: LineRange?) throws -> CanvasObject {
        let tile = try object(follow)
        var props: [String: JSONValue] = ["path": .string(path), "diffBase": tile.props["diffBase"] ?? .string("merge-base")]
        if let range { props["range"] = .object(["start": .number(Double(range.start)), "end": .number(Double(range.end))]) }
        if let caption = tile.props["caption"] { props["caption"] = caption }
        return create(type: .code, props: .object(props), frame: place(width: tile.frame.w, height: tile.frame.h, near: follow))
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
