import Foundation

@MainActor
extension UndoHistory.Step {
    private enum Verb: Int {
        case create, delete, move, resize, restack, change, review

        var past: String { ["created", "deleted", "moved", "resized", "restacked", "changed", "applied"][rawValue] }
        var imperative: String { ["Create", "Delete", "Move", "Resize", "Restack", "Change", "Apply"][rawValue] }
    }

    /// What the step did, verb by verb in the order it did them, each with the objects it did it
    /// to by type. Updates of objects the step created or deleted are part of that; a group
    /// re-fitted or an arrow re-routed because its members moved is left out beside anything else.
    private var parts: [(verb: Verb, types: [(type: ObjectType?, count: Int)])] {
        var born: Set<ObjectID> = []
        var effects = false
        for change in changes {
            switch change {
            case .created(let object), .deleted(let object): born.insert(object.id)
            case .effect: effects = true
            case .updated: break
            }
        }
        var entries: [(verb: Verb, type: ObjectType?)] = []
        for change in changes {
            switch change {
            case .created(let object): entries.append((.create, object.type))
            case .deleted(let object): entries.append((.delete, object.type))
            case .effect: entries.append((.review, nil))
            case .updated(let before, let after):
                guard !born.contains(after.id), !(effects && after.type == .changes) else { continue }
                let old = UndoHistory.content(before), new = UndoHistory.content(after)
                let verb: Verb = old.props != new.props || old.parent != new.parent ? .change
                    : (old.frame.w, old.frame.h) != (new.frame.w, new.frame.h) ? .resize
                    : (old.frame.x, old.frame.y) != (new.frame.x, new.frame.y) ? .move : .restack
                entries.append((verb, after.type))
            }
        }
        let cascade: ((verb: Verb, type: ObjectType?)) -> Bool = { ($0.type == .group || $0.type == .arrow) && ($0.verb == .move || $0.verb == .resize) }
        if entries.contains(where: { !cascade($0) }) { entries.removeAll(where: cascade) }
        var result: [(verb: Verb, types: [(type: ObjectType?, count: Int)])] = []
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

    private static func noun(_ type: ObjectType?) -> (singular: String, plural: String, title: String) {
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
        case nil: ("review action", "review actions", "Review Action")
        }
    }

    /// What undoing it undoes, for a person: `created 9 code tiles, 6 arrows; moved a note`.
    public var summary: String {
        parts.map { part in
            part.verb.past + " " + part.types.map { entry in
                let noun = Self.noun(entry.type)
                guard entry.count == 1 else { return "\(entry.count) \(noun.plural)" }
                return (["a", "e", "i", "o", "u", "H"].contains(noun.singular.prefix(1)) ? "an " : "a ") + noun.singular
            }.joined(separator: ", ")
        }.joined(separator: "; ")
    }

    /// The Edit menu's name for it (`Undo <title>`): `Create 9 Code Tiles, 6 Arrows`, `Move Note`.
    public var title: String {
        let shown = parts.prefix(2).map { part in
            part.verb.imperative + " " + part.types.map { entry in
                let noun = Self.noun(entry.type).title
                return entry.count == 1 ? noun : "\(entry.count) \(noun)s"
            }.joined(separator: ", ")
        }
        return shown.joined(separator: "; ") + (parts.count > 2 ? "…" : "")
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
