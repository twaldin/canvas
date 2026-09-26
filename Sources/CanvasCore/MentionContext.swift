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
        case .code(_, let path, let lines, _, let symbol):
            let range = lines.start == lines.end ? "\(lines.start)" : "\(lines.start)-\(lines.end)"
            return symbol.map { "\(path):\(range) \($0)" } ?? "\(path):\(range)"
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

    public static func resolve(_ mention: Mention, index: Int, on board: Board) -> Resolved {
        let edited = mention.edited ? " (edited)" : ""
        var lines: [String] = []
        switch mention.target {
        case .code(let object, let path, let range, let side, let symbol):
            let symbolText = symbol.map { " (symbol \($0))" } ?? ""
            let sideText = side == "old" ? " · old side of diff" : ""
            lines.append("[\(index)] code \(path):\(range.start)-\(range.end)\(symbolText) · tile \(object)\(sideText)\(edited)")
            lines.append(contentsOf: excerpt(board.absoluteURL(path), range))
        case .dom(let object, let url, let selector, let text):
            let textPart = text.map { " \"\(clip($0, 80))\"" } ?? ""
            lines.append("[\(index)] dom \(url) · \(selector)\(textPart) · browser tile \(object)\(edited)")
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
        out.append("Read more with the canvas SDK or CLI: canvas get <id> --as graph|image")
        out.append("</canvas-mentions>")
        return out.joined(separator: "\n")
    }

    /// One-line description with spatial relations: what a shape encloses and its arrows.
    static func describe(_ object: CanvasObject, on board: Board) -> String {
        let author = object.createdBy == .user ? "drawn by user" : "by agent"
        var parts = ["\(object.type.rawValue) \(object.id)"]
        let title = title(of: object)
        if !title.isEmpty { parts.append("\"\(clip(title, 60))\"") }
        if object.type == .shape { parts.append("(\(author))") }
        let enclosed = board.objects.values.filter { $0.id != object.id && $0.type != .arrow && object.frame.contains($0.frame) }.map(\.id).sorted()
        if object.type == .shape, !enclosed.isEmpty { parts.append("· encloses \(enclosed.joined(separator: ", "))") }
        for arrow in board.objects.values where arrow.type == .arrow {
            let relation = arrow.props["relation"]?.string.map { " (\($0))" } ?? ""
            if arrow.props["from"]?["object"]?.string == object.id, let to = arrow.props["to"]?["object"]?.string {
                parts.append("· arrow → \(to)\(relation)")
            } else if arrow.props["to"]?["object"]?.string == object.id, let from = arrow.props["from"]?["object"]?.string {
                parts.append("· arrow ← \(from)\(relation)")
            }
        }
        return parts.joined(separator: " ")
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
        case .group: return props["name"]?.string ?? ""
        }
    }

    /// The mentioned lines marked `>`, plus up to `contextLines` unmarked lines on each side while
    /// the whole excerpt fits in `maxExcerptLines`, so a one-line mention still reads in context.
    static func excerpt(_ url: URL, _ range: LineRange) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ["    (file unreadable: \(url.path))"] }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(1, range.start)
        let end = min(all.count, range.end)
        guard start <= end else { return ["    (range \(range.start)-\(range.end) is outside the file)"] }
        let pad = min(contextLines, max(0, maxExcerptLines - (end - start + 1)) / 2)
        let from = max(1, start - pad)
        let to = min(all.count, end + pad, from + maxExcerptLines - 1)
        var lines = (from...to).map { number in
            let marker = (start...end).contains(number) ? "  > " : "    "
            return marker + String(number).padding(toLength: 5, withPad: " ", startingAt: 0) + all[number - 1]
        }
        if range.end > to { lines.append("    …") }
        return lines
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
