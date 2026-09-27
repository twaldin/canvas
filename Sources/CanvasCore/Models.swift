import Foundation

/// Mirrors `definitions` in schema/canvas-api.json. Change the schema first.
public typealias ObjectID = String
public typealias BoardID = String
public typealias MentionID = String

public enum IDs {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Prefixed, time-sortable id: `obj_01J…`.
    public static func make(_ prefix: String) -> String {
        var value = UInt64(Date().timeIntervalSince1970 * 1000)
        var time = ""
        for _ in 0..<10 {
            time.insert(alphabet[Int(value & 31)], at: time.startIndex)
            value >>= 5
        }
        let random = (0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
        return "\(prefix)_\(time)\(String(random))"
    }
}

public struct Frame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var maxX: Double { x + w }
    public var maxY: Double { y + h }

    public func intersects(_ other: Frame) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    public func contains(_ other: Frame) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }
}

public enum Actor: Codable, Equatable, Sendable {
    case user
    case agent(tile: ObjectID)

    private enum CodingKeys: String, CodingKey { case kind, tile }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "agent": self = .agent(tile: try container.decode(String.self, forKey: .tile))
        default: self = .user
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try container.encode("user", forKey: .kind)
        case .agent(let tile):
            try container.encode("agent", forKey: .kind)
            try container.encode(tile, forKey: .tile)
        }
    }

    /// Callers identify themselves by terminal tile id; no caller means the user.
    public init(caller: ObjectID?) {
        self = caller.map { .agent(tile: $0) } ?? .user
    }
}

public enum ObjectType: String, Codable, Sendable, CaseIterable {
    case terminal, browser, code, note, html, changes, image, shape, arrow, group

    /// The props this type defines (schema `TerminalProps` … `GroupProps`). Others are kept but
    /// reported: `object.create`/`object.update` name them in `warnings`.
    public var knownProps: Set<String> {
        switch self {
        case .terminal: ["cwd", "command", "zmxSession", "title", "name", "agent", "lifecycle", "follow", "scale"]
        case .browser: ["url", "title", "pageTitle", "scale"]
        case .code: ["path", "range", "symbol", "caption", "diffBase", "followOf", "lastAction", "history", "pinnedCommit", "scale"]
        case .note: ["markdown", "title", "scale"]
        case .html: ["html", "title", "allowNetwork", "state", "scale"]
        case .changes: ["root", "base", "paths", "title", "reviewed", "viewed", "scale"]
        case .image: ["path", "caption", "title", "scale"]
        case .shape: ["kind", "text", "points", "color", "fill", "scale"]
        case .arrow: ["from", "to", "relation", "label", "color", "route"]
        case .group: ["members", "title", "color", "padding"]
        }
    }

    /// One warning per key of `props` this type doesn't define, in key order.
    public func unknownPropWarnings(_ props: JSONValue?) -> [String] {
        guard let keys = props?.object?.keys else { return [] }
        let known = knownProps
        return keys.filter { !known.contains($0) }.sorted().map { key in
            "unknown prop \"\(key)\" for \(rawValue) (kept, but nothing reads it; \(rawValue) props: \(known.sorted().joined(separator: ", ")))"
        }
    }
}

public struct CanvasObject: Codable, Equatable, Sendable {
    public var id: ObjectID
    public var type: ObjectType
    public var frame: Frame
    public var z: Double
    public var rev: Int
    public var parent: ObjectID?
    public var createdBy: Actor
    public var updatedBy: Actor?
    public var createdAt: Date
    public var updatedAt: Date
    public var props: JSONValue

    public init(id: ObjectID, type: ObjectType, frame: Frame, z: Double, rev: Int = 1, parent: ObjectID? = nil, createdBy: Actor, createdAt: Date, props: JSONValue) {
        self.id = id
        self.type = type
        self.frame = frame
        self.z = z
        self.rev = rev
        self.parent = parent
        self.createdBy = createdBy
        self.updatedBy = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.props = props
    }
}

public struct LineRange: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public enum MentionTarget: Codable, Equatable, Sendable {
    case object(ObjectID)
    /// `commit`: with `side` old or absent, the commit whose version of `path` holds `lines`
    /// (a deleted diff row, a pinned excerpt); with `side` new, the base the working-tree lines
    /// were diffed against. Absent: the lines are in the working tree. `diff`: a changes tile's
    /// word on the lines, e.g. `added line · unstaged hunk` (`ChangeSet.mentionDetail`).
    case code(object: ObjectID, path: String, lines: LineRange, side: String? = nil, symbol: String? = nil, commit: String? = nil, diff: String? = nil)
    case dom(object: ObjectID, url: String, selector: String, text: String?)
    /// Terminal text: the user's selection, the screen rows around a click, or one command's
    /// block (its output; `command` says what ran, with exit status and duration when known).
    case terminal(object: ObjectID, text: String, part: TerminalPart = .selection, command: TerminalCommand? = nil)
    case group(objects: [ObjectID], name: String?)
    /// A point on an image tile's picture, in the image's own pixels from its top-left.
    case image(object: ObjectID, path: String, x: Int, y: Int)

    private enum CodingKeys: String, CodingKey { case kind, object, path, lines, side, symbol, commit, diff, url, selector, text, objects, name, x, y, part, command }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "code":
            self = .code(object: try c.decode(String.self, forKey: .object), path: try c.decode(String.self, forKey: .path), lines: try c.decode(LineRange.self, forKey: .lines), side: try c.decodeIfPresent(String.self, forKey: .side), symbol: try c.decodeIfPresent(String.self, forKey: .symbol), commit: try c.decodeIfPresent(String.self, forKey: .commit), diff: try c.decodeIfPresent(String.self, forKey: .diff))
        case "dom":
            self = .dom(object: try c.decode(String.self, forKey: .object), url: try c.decode(String.self, forKey: .url), selector: try c.decode(String.self, forKey: .selector), text: try c.decodeIfPresent(String.self, forKey: .text))
        case "terminal":
            self = .terminal(object: try c.decode(String.self, forKey: .object), text: try c.decode(String.self, forKey: .text),
                             part: try c.decodeIfPresent(TerminalPart.self, forKey: .part) ?? .selection, command: try c.decodeIfPresent(TerminalCommand.self, forKey: .command))
        case "group":
            self = .group(objects: try c.decode([String].self, forKey: .objects), name: try c.decodeIfPresent(String.self, forKey: .name))
        case "image":
            self = .image(object: try c.decode(String.self, forKey: .object), path: try c.decode(String.self, forKey: .path), x: try c.decode(Int.self, forKey: .x), y: try c.decode(Int.self, forKey: .y))
        case "object":
            self = .object(try c.decode(String.self, forKey: .object))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown mention kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .object(let id):
            try c.encode("object", forKey: .kind)
            try c.encode(id, forKey: .object)
        case .code(let object, let path, let lines, let side, let symbol, let commit, let diff):
            try c.encode("code", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(path, forKey: .path)
            try c.encode(lines, forKey: .lines)
            try c.encodeIfPresent(side, forKey: .side)
            try c.encodeIfPresent(symbol, forKey: .symbol)
            try c.encodeIfPresent(commit, forKey: .commit)
            try c.encodeIfPresent(diff, forKey: .diff)
        case .dom(let object, let url, let selector, let text):
            try c.encode("dom", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(url, forKey: .url)
            try c.encode(selector, forKey: .selector)
            try c.encodeIfPresent(text, forKey: .text)
        case .terminal(let object, let text, let part, let command):
            try c.encode("terminal", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(text, forKey: .text)
            if part != .selection { try c.encode(part, forKey: .part) }
            try c.encodeIfPresent(command, forKey: .command)
        case .group(let objects, let name):
            try c.encode("group", forKey: .kind)
            try c.encode(objects, forKey: .objects)
            try c.encodeIfPresent(name, forKey: .name)
        case .image(let object, let path, let x, let y):
            try c.encode("image", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(path, forKey: .path)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        }
    }

    /// Objects this mention depends on; deleting any of them removes the mention.
    public var objectIDs: [ObjectID] {
        switch self {
        case .object(let id): [id]
        case .code(let object, _, _, _, _, _, _), .dom(let object, _, _, _), .terminal(let object, _, _, _), .image(let object, _, _, _): [object]
        case .group(let objects, _): objects
        }
    }
}

/// Which part of a terminal a terminal mention holds.
public enum TerminalPart: String, Codable, Sendable {
    /// What the user selected.
    case selection
    /// The screen rows around a Hyper-click, the clicked row marked.
    case rows
    /// One command's output, as the shell integration marks it.
    case command
}

public struct Mention: Codable, Equatable, Sendable {
    public var id: MentionID
    public var target: MentionTarget
    public var label: String
    public var stagedAt: Date
    public var edited: Bool

    public init(id: MentionID, target: MentionTarget, label: String, stagedAt: Date, edited: Bool = false) {
        self.id = id
        self.target = target
        self.label = label
        self.stagedAt = stagedAt
        self.edited = edited
    }
}

public enum LifecycleState: String, Codable, Sendable {
    case working, blocked, idle, done, unknown
}
