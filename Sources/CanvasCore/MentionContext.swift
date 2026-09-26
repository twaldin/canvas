import Foundation

/// Turns staged mentions into the `<canvas-mentions>` prompt block (docs/contracts.md).
@MainActor
public enum MentionContext {
    public struct Resolved: Codable, Equatable, Sendable {
        public var id: MentionID
        public var ref: String
        public var label: String
        public var summary: String
    }

    static let maxExcerptLines = 12
    static let contextLines = 3

    public static func label(for target: MentionTarget, on board: Board) -> String {
        switch target {
        case .code(_, let path, let lines, let side, let symbol, _):
            let range = lines.start == lines.end ? "\(lines.start)" : "\(lines.start)-\(lines.end)"
            let location = side == DiffSide.old.rawValue ? "\(path):\(range) (old)" : "\(path):\(range)"
            return symbol.map { "\(location) \($0)" } ?? location
        case .dom(_, _, let selector, let text):
            return text.map { "\(selector) \"\(clip($0, 24))\"" } ?? selector
        case .terminal(_, let text):
            return "terminal \"\(clip(text, 28))\""
        case .group(let objects, let name):
            return name ?? "\(objects.count) objects"
        case .object(let id):
            guard let object = board.objects[id] else { return id }
            return "\(object.type.rawValue) \(clip(title(of: object), 28))"
        }
    }

    public static func resolve(_ mention: Mention, index: Int, on board: Board) async -> Resolved {
        let edited = mention.edited ? " (edited)" : ""
        var lines: [String] = []
        switch mention.target {
        case .code(let object, let path, let range, let side, let symbol, let commit):
            let symbolText = symbol.map { " (symbol \($0))" } ?? ""
            lines.append("[\(index)] code \(path):\(range.start)-\(range.end)\(symbolText) · tile \(object)\(provenance(of: object, side: side, commit: commit, on: board))\(edited)")
            let url = board.absoluteURL(path)
            if let commit, side != DiffSide.new.rawValue {
                // The mention names its commit, so the excerpt never depends on what the tile
                // shows now.
                let text = await GitDiffEngine.shared.text(of: url, at: commit)
                lines.append(contentsOf: text.map { excerpt($0, range) } ?? ["    (\(path) is not readable at \(commit.prefix(7)))"])
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                lines.append(contentsOf: excerpt(SideText(text), range))
            } else {
                lines.append("    (file unreadable: \(url.path))")
            }
        case .dom(let object, let url, let selector, let text):
            let textPart = text.map { " \"\(clip($0, 80))\"" } ?? ""
            lines.append("[\(index)] dom \(url) · \(selector)\(textPart) · \(board.objects[object]?.type.rawValue ?? "browser") tile \(object)\(edited)")
        case .terminal(let object, let text):
            lines.append("[\(index)] terminal tile \(object)\(edited)")
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxExcerptLines).map { "    \($0)" })
        case .group(let objects, let name):
            lines.append("[\(index)] group \(name.map { "\"\($0)\" " } ?? "")of \(objects.count) objects\(edited)")
            for id in objects {
                if let object = board.objects[id] { lines.append("    - \(describe(object, on: board))") }
            }
        case .object(let id):
            if let object = board.objects[id] {
                lines.append("[\(index)] \(describe(object, on: board))\(edited)")
                if object.type == .note, let markdown = object.props["markdown"]?.string {
                    lines.append(contentsOf: markdown.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxExcerptLines).map { "    \($0)" })
                }
            } else {
                lines.append("[\(index)] object \(id) (deleted)")
            }
        }
        let rev = mention.target.objectIDs.first.flatMap { board.objects[$0]?.rev }.map { "@rev\($0)" } ?? ""
        return Resolved(id: mention.id, ref: "canvas:\(mention.id)\(rev)", label: mention.label, summary: lines.joined(separator: "\n"))
    }

    public static func render(_ resolved: [Resolved], board: Board) -> String {
        guard !resolved.isEmpty else { return "" }
        var out = ["<canvas-mentions board=\"\(board.id)\" root=\"\(board.root.path)\">"]
        out.append(contentsOf: resolved.map(\.summary))
        out.append("Read more with the canvas SDK or CLI: canvas get <id> --as graph; look with canvas render <id>")
        out.append("</canvas-mentions>")
        return out.joined(separator: "\n")
    }

    /// One-line description with spatial relations: what a shape encloses, what it's drawn on, and its arrows.
    static func describe(_ object: CanvasObject, on board: Board) -> String {
        let author = object.createdBy == .user ? "drawn by user" : "by agent"
        var parts = ["\(object.type.rawValue) \(object.id)"]
        let title = title(of: object)
        if !title.isEmpty { parts.append("\"\(clip(title, 60))\"") }
        if object.type == .shape { parts.append("(\(author))") }
        if object.type == .shape {
            let enclosed = board.enclosed(by: object).map(\.id)
            if !enclosed.isEmpty { parts.append("· encloses \(enclosed.joined(separator: ", "))") }
            for (_, spec) in board.arrows(enclosedBy: object) {
                let relation = spec.relation.map { " (\($0))" } ?? ""
                parts.append("· inner arrow \(endName(spec.from)) → \(endName(spec.to))\(relation)")
            }
            // A box drawn on top of something (a tile region, a bigger box) points at part of it:
            // name the topmost object underneath that contains it, and where, in its local units.
            let region = object.frame.rect
            if let host = board.objects.values.filter({ $0.type != .arrow && $0.type != .group && $0.z < object.z && $0.frame.rect.contains(region) }).max(by: { $0.z < $1.z }) {
                let local = region.offsetBy(dx: -host.frame.rect.minX, dy: -host.frame.rect.minY)
                parts.append(String(format: "· over %@ %@ at (%.0f, %.0f) %.0f×%.0f", host.type.rawValue, host.id,
                                    Double(local.minX), Double(local.minY), Double(local.width), Double(local.height)))
            }
        }
        for arrow in board.objects.values where arrow.type == .arrow {
            let relation = arrow.props["relation"]?.string.map { " (\($0))" } ?? ""
            if arrow.props["from"]?["object"]?.string == object.id, let to = arrow.props["to"]?["object"]?.string {
                parts.append("· arrow → \(to)\(relation)")
            } else if arrow.props["to"]?["object"]?.string == object.id, let from = arrow.props["from"]?["object"]?.string {
                parts.append("· arrow ← \(from)\(relation)")
            }
        }
        if object.type == .arrow, let spec = ArrowSpec(object.props) {
            let relation = spec.relation.map { " (\($0))" } ?? ""
            parts.append("· \(endName(spec.from)) → \(endName(spec.to))\(relation)")
        }
        return parts.joined(separator: " ")
    }

    static func endName(_ binding: ArrowBinding) -> String {
        switch binding {
        case .object(let id, let lines, let selector):
            let detail = lines.map { ":\($0.start)-\($0.end)" } ?? selector.map { " \($0)" } ?? ""
            return id + detail
        case .point(let point):
            // Coordinates are any JSON number; an Int conversion would trap on huge ones.
            return String(format: "(%.0f, %.0f)", Double(point.x), Double(point.y))
        }
    }

    static func title(of object: CanvasObject) -> String {
        let props = object.props
        switch object.type {
        case .terminal: return props["title"]?.string ?? props["agent"]?["kind"]?.string ?? "terminal"
        case .browser: return props["title"]?.string ?? props["url"]?.string ?? ""
        case .code: return props["path"]?.string ?? ""
        case .note: return props["markdown"]?.string?.split(separator: "\n").first.map(String.init) ?? ""
        case .html: return props["title"]?.string ?? "html"
        case .shape: return props["text"]?.string ?? props["kind"]?.string ?? ""
        case .arrow: return props["label"]?.string ?? props["relation"]?.string ?? ""
        case .group: return props["title"]?.string ?? ""
        }
    }

    /// Where the lines come from, from the mention alone: ` · diff vs merge-base 1a2b3c4` (plus
    /// `, old side` for deleted rows), ` · at 1a2b3c4` for a pinned excerpt, nothing for the
    /// working tree. The tile's `diffBase` only names the kind of base.
    static func provenance(of object: ObjectID, side: String?, commit: String?, on board: Board) -> String {
        guard let commit else { return side == DiffSide.old.rawValue ? " · old side of diff" : "" }
        let sha = commit.prefix(7)
        guard side != nil else { return " · at \(sha)" }
        let kind = board.objects[object].map { $0.type == .code ? DiffBase(prop: $0.props["diffBase"]?.string).name + " " : "" } ?? ""
        return " · diff vs \(kind)\(sha)\(side == DiffSide.old.rawValue ? ", old side" : "")"
    }

    /// The mentioned lines marked `>`, plus up to `contextLines` unmarked lines on each side while
    /// the whole excerpt fits in `maxExcerptLines`, so a one-line mention still reads in context.
    static func excerpt(_ text: SideText, _ range: LineRange) -> [String] {
        let start = max(1, range.start)
        let end = min(text.lineCount, range.end)
        guard start <= end else { return ["    (range \(range.start)-\(range.end) is outside the file)"] }
        let pad = min(contextLines, max(0, maxExcerptLines - (end - start + 1)) / 2)
        let from = max(1, start - pad)
        let to = min(text.lineCount, end + pad, from + maxExcerptLines - 1)
        var lines = (from...to).map { number in
            let marker = (start...end).contains(number) ? "  > " : "    "
            return marker + String(number).padding(toLength: 5, withPad: " ", startingAt: 0) + text.line(number)
        }
        if range.end > to { lines.append("    …") }
        return lines
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
