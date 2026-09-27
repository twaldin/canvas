import Foundation

@MainActor
extension UndoHistory.Step {
    private enum Verb: Int {
        case create, delete, move, resize, restack, change

        var past: String { ["created", "deleted", "moved", "resized", "restacked", "changed"][rawValue] }
        var imperative: String { ["Create", "Delete", "Move", "Resize", "Restack", "Change"][rawValue] }
    }

    /// What the step did outside the board, by name (`Stage of src/a.rs`), in order.
    public var effectNames: [String] {
        changes.compactMap { change in
            if case .effect(let effect) = change { return effect.name }
            return nil
        }
    }

    /// What the step did to the board, verb by verb in the order it did them, each with the
    /// objects it did it to by type. Updates of objects the step created or deleted are part of
    /// that; a group re-fitted or an arrow re-routed because its members moved is left out beside
    /// anything else; the changes tile's own log of a git action (`props.reviewed`) is the
    /// action, named in `effectNames`.
    private var parts: [(verb: Verb, types: [(type: ObjectType, count: Int)])] {
        var born: Set<ObjectID> = []
        var effects = false
        for change in changes {
            switch change {
            case .created(let object), .deleted(let object): born.insert(object.id)
            case .effect: effects = true
            case .updated: break
            }
        }
        var entries: [(verb: Verb, type: ObjectType)] = []
        for change in changes {
            switch change {
            case .created(let object): entries.append((.create, object.type))
            case .deleted(let object): entries.append((.delete, object.type))
            case .effect: continue
            case .updated(let before, let after):
                guard !born.contains(after.id), !(effects && after.type == .changes) else { continue }
                let old = UndoHistory.content(before), new = UndoHistory.content(after)
                let verb: Verb = old.props != new.props || old.parent != new.parent ? .change
                    : (old.frame.w, old.frame.h) != (new.frame.w, new.frame.h) ? .resize
                    : (old.frame.x, old.frame.y) != (new.frame.x, new.frame.y) ? .move : .restack
                entries.append((verb, after.type))
            }
        }
        let cascade: ((verb: Verb, type: ObjectType)) -> Bool = { ($0.type == .group || $0.type == .arrow) && ($0.verb == .move || $0.verb == .resize) }
        if entries.contains(where: { !cascade($0) }) { entries.removeAll(where: cascade) }
        var result: [(verb: Verb, types: [(type: ObjectType, count: Int)])] = []
        for entry in entries {
            let index = result.firstIndex { $0.verb == entry.verb } ?? {
                result.append((entry.verb, []))
                return result.count - 1
            }()
            if let typeIndex = result[index].types.firstIndex(where: { $0.type == entry.type }) {
                result[index].types[typeIndex].count += 1
            } else {
                result[index].types.append((entry.type, 1))
            }
        }
        return result
    }

    private static func noun(_ type: ObjectType) -> (singular: String, plural: String, title: String) {
        switch type {
        case .code: ("code tile", "code tiles", "Code Tile")
        case .terminal: ("terminal", "terminals", "Terminal")
        case .note: ("note", "notes", "Note")
        case .html: ("HTML tile", "HTML tiles", "HTML Tile")
        case .changes: ("changes tile", "changes tiles", "Changes Tile")
        case .image: ("image", "images", "Image")
        case .browser: ("browser tile", "browser tiles", "Browser Tile")
        case .shape: ("shape", "shapes", "Shape")
        case .arrow: ("arrow", "arrows", "Arrow")
        case .group: ("group", "groups", "Group")
        }
    }

    /// What undoing it undoes, for a person: `created 9 code tiles, 6 arrows; moved a note`,
    /// `Stage of src/a.rs`.
    public var summary: String {
        (effectNames + parts.map { part in
            part.verb.past + " " + part.types.map { entry in
                let noun = Self.noun(entry.type)
                guard entry.count == 1 else { return "\(entry.count) \(noun.plural)" }
                return (["a", "e", "i", "o", "u", "H"].contains(noun.singular.prefix(1)) ? "an " : "a ") + noun.singular
            }.joined(separator: ", ")
        }).joined(separator: "; ")
    }

    /// The Edit menu's name for it (`Undo <title>`): `Create 9 Code Tiles, 6 Arrows`, `Move Note`,
    /// `Stage of src/a.rs`.
    public var title: String {
        let shown = effectNames + parts.map { part in
            part.verb.imperative + " " + part.types.map { entry in
                let noun = Self.noun(entry.type).title
                return entry.count == 1 ? noun : "\(entry.count) \(noun)s"
            }.joined(separator: ", ")
        }
        return shown.prefix(2).joined(separator: "; ") + (shown.count > 2 ? "…" : "")
    }

    /// The notice an undo (`redo` false) or redo of the step shows, nil when it needs none: one
    /// someone else made (`author`, `Undid omp: created 9 code tiles · ⇧⌘Z redoes`) or one that
    /// changed the user's files or git index (`Undid Stage of src/a.rs · ⇧⌘Z redoes`), which
    /// nothing on the board shows happening.
    public func notice(redo: Bool, author: String?) -> String? {
        guard author != nil || !effectNames.isEmpty else { return nil }
        let verb = redo ? "Redid" : "Undid", again = redo ? "⌘Z undoes" : "⇧⌘Z redoes"
        return "\(verb) \(author.map { "\($0): " } ?? "")\(summary) · \(again)"
    }
}

extension Board {
    /// The step ⌘Z would undo and ⇧⌘Z redo.
    public var nextUndo: UndoHistory.Step? { history.undoSteps.last }
    public var nextRedo: UndoHistory.Step? { history.redoSteps.last }

    /// How undo names who made a step: the agent terminal's name, else its agent's kind (`omp`),
    /// else "an agent"; nil for the user.
    public func authorName(_ author: Actor) -> String? {
        guard case .agent(let tile) = author else { return nil }
        let terminal = objects[tile]
        if let name = terminal?.props["name"]?.string, !name.isEmpty { return name }
        if let kind = terminal?.props["agent"]?["kind"]?.string, !kind.isEmpty { return kind }
        return "an agent"
    }
}
