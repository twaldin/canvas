import Foundation
import Markdown

/// The block of a note's markdown a Hyper-click in the note mentions (`MentionTarget.note`):
/// the paragraph, list item (with its nested items), blockquote, table row, or fence under the
/// pointer, or a heading with its section. Pure: callers supply the markdown and the 1-based
/// markdown line the clicked paragraph was rendered from (`.noteMarkdownLine`).
public struct NoteItem: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case paragraph, item, heading, quote, code, row, html

        /// How the mention context names it.
        public var noun: String {
            switch self {
            case .paragraph: "paragraph"
            case .item: "list item"
            case .heading: "section"
            case .quote: "quote"
            case .code: "code block"
            case .row: "table row"
            case .html: "html block"
            }
        }
    }

    public var kind: Kind
    /// The headings of the sections it sits in, outermost first (a heading's own section: the
    /// ones above it).
    public var headings: [String]
    /// Its markdown lines, 1-based.
    public var lines: LineRange
    /// Its markdown: whole lines, the common indentation removed, cut to `maxLines` lines and
    /// `maxCharacters` characters (`truncated`).
    public var text: String

    /// A mention carries a block, not a chapter.
    public static let maxLines = 40
    public static let maxCharacters = 2000

    public init(kind: Kind, headings: [String], lines: LineRange, text: String) {
        self.kind = kind
        self.headings = headings
        self.lines = lines
        self.text = text
    }

    /// Lines of the block `text` leaves out.
    public var omittedLines: Int {
        max(0, lines.end - lines.start + 1 - NoteSource.lines(of: text).count)
    }

    /// The block containing markdown line `line`; nil on a blank line between blocks, a
    /// thematic break, or past the end.
    public static func at(line: Int, in markdown: String) -> NoteItem? {
        let source = NoteSource.lines(of: markdown)
        guard source.indices.contains(line - 1) else { return nil }
        let document = NoteMarkdown.parse(markdown)
        var chain: [Markup] = []
        var container: Markup = document
        while let child = container.children.first(where: { $0 is BlockMarkup && contains($0, line) }) {
            chain.append(child)
            container = child
        }
        guard let leaf = chain.last else { return nil }
        let headings = sections(of: document)
        let kind: Kind
        let range: ClosedRange<Int>
        if let block = chain.first(where: { $0 is CodeBlock || $0 is HTMLBlock }), let span = span(of: block) {
            kind = block is CodeBlock ? .code : .html
            range = span
        } else if let table = chain.first(where: { $0 is Table }), let span = span(of: table) {
            // Rows are one line each; the delimiter row stands for the header.
            kind = .row
            let row = line == span.lowerBound + 1 ? span.lowerBound : line
            range = row...row
        } else if let item = chain.last(where: { $0 is ListItem }), let span = span(of: item) {
            kind = .item
            range = span
        } else if let quote = chain.first(where: { $0 is BlockQuote }), let span = span(of: quote) {
            kind = .quote
            range = span
        } else if let heading = leaf as? Heading, chain.count == 1, let start = heading.range?.lowerBound.line {
            // The section: up to the next heading of the same or a higher level.
            kind = .heading
            let next = headings.first { $0.line > start && $0.level <= heading.level }?.line ?? source.count + 1
            range = start...(next - 1)
        } else if leaf is Paragraph, let span = span(of: leaf) {
            kind = .paragraph
            range = span
        } else {
            return nil
        }
        var end = range.upperBound
        while end > range.lowerBound, source[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return NoteItem(kind: kind, headings: path(to: range.lowerBound, in: headings),
                        lines: LineRange(start: range.lowerBound, end: end), text: excerpt(source[(range.lowerBound - 1)..<end]))
    }

    /// Where a block mentioned as `text` (at `near`) is in `markdown` now: the block starting
    /// where its lines are again (ignoring indentation), nearest `near`; else the block starting
    /// at its first line, when that is still somewhere. `unchanged`: the block reads as mentioned.
    public static func find(_ text: String, near: Int, in markdown: String) -> (item: NoteItem, unchanged: Bool)? {
        let wanted = NoteSource.lines(of: text).map(normalized)
        guard let first = wanted.first, !first.isEmpty else { return nil }
        let source = NoteSource.lines(of: markdown).map(normalized)
        let starts = source.indices.filter { source[$0] == first }
        let whole = starts.filter { start in
            start + wanted.count <= source.count && Array(source[start..<(start + wanted.count)]) == wanted
        }
        func nearest(_ candidates: [Int]) -> NoteItem? {
            candidates.sorted { abs($0 + 1 - near) < abs($1 + 1 - near) }.lazy
                .compactMap { start in at(line: start + 1, in: markdown).flatMap { $0.lines.start == start + 1 ? $0 : nil } }.first
        }
        if let item = nearest(whole) { return (item, item.text == text) }
        if let item = nearest(starts) { return (item, false) }
        return nil
    }

    /// A few words naming it, as its chip does: the item's own text (an ordered item's number
    /// first), the heading, the row's cells, a fence's first line of code.
    public var summary: String {
        let lines = NoteSource.lines(of: text)
        switch kind {
        case .row:
            return lines.first.map { row in
                row.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ")
            } ?? ""
        case .code, .html:
            let body = kind == .code ? lines.dropFirst() : lines[...]
            return body.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces) ?? ""
        default:
            var number: String?
            var node: Markup = NoteMarkdown.parse(text)
            while let child = node.child(at: 0) {
                if let list = child as? OrderedList, number == nil { number = "\(list.startIndex)." }
                if let inline = child as? InlineContainer {
                    return [number, inline.plainText].compactMap { $0 }.joined(separator: " ")
                }
                node = child
            }
            return lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        }
    }

    // MARK: Helpers

    private static func contains(_ markup: Markup, _ line: Int) -> Bool {
        span(of: markup)?.contains(line) ?? false
    }

    private static func span(of markup: Markup) -> ClosedRange<Int>? {
        guard let range = markup.range else { return nil }
        return range.lowerBound.line...max(range.lowerBound.line, range.upperBound.line)
    }

    /// Top-level headings in order, with their lines.
    private static func sections(of document: Document) -> [(line: Int, level: Int, title: String)] {
        document.children.compactMap { child in
            guard let heading = child as? Heading, let line = heading.range?.lowerBound.line else { return nil }
            return (line, heading.level, heading.plainText)
        }
    }

    /// The headings whose sections hold `line`, outermost first. Levels may skip (`#` then `###`).
    private static func path(to line: Int, in headings: [(line: Int, level: Int, title: String)]) -> [String] {
        var stack: [(level: Int, title: String)] = []
        for heading in headings where heading.line < line {
            while let top = stack.last, top.level >= heading.level { stack.removeLast() }
            stack.append((heading.level, heading.title))
        }
        return stack.map(\.title)
    }

    private static func excerpt(_ lines: ArraySlice<String>) -> String {
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        var kept: [String] = []
        var count = 0
        for line in lines.prefix(maxLines) {
            let text = String(line.dropFirst(min(indent, line.prefix { $0 == " " || $0 == "\t" }.count)))
            if count + text.count > maxCharacters {
                if kept.isEmpty { kept.append(String(text.prefix(maxCharacters - 1)) + "…") }
                break
            }
            kept.append(text)
            count += text.count + 1
        }
        return kept.joined(separator: "\n")
    }

    private static func normalized(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }
}
