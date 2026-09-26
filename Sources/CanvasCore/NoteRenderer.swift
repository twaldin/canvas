import AppKit
import Markdown

/// Markdown → attributed text for the note display (TextKit 2). Prose is styled as authored;
/// anchored fences render what `NoteSource` resolved from disk, keyed by their info string.
@MainActor
public final class NoteRenderer {
    public static let bodyFont = NSFont.systemFont(ofSize: 13)
    public static let codeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    public static let captionFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    /// Rows past this in one excerpt are summarized; a whole-file excerpt stays cheap to lay out.
    static let maxRows = 400

    private let excerpts: [String: NoteExcerpt]
    private let out = NSMutableAttributedString()

    public init(excerpts: [String: NoteExcerpt]) {
        self.excerpts = excerpts
    }

    /// Nesting state for block rendering.
    private struct Context {
        var indent: CGFloat = 0
        var quoted = false
        /// List marker for the next paragraph (the first one of a list item).
        var marker: String?
        var markerWidth: CGFloat = 0
    }

    public func render(_ document: Document, placeholder: String) -> NSAttributedString {
        if document.childCount == 0 {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            out.append(NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: style,
            ]))
            return out
        }
        var context = Context()
        blocks(document, &context)
        // Every block ends its paragraph; the last one needs no empty paragraph after it.
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    // MARK: Blocks

    private func blocks(_ container: Markup, _ context: inout Context) {
        for child in container.children { block(child, &context) }
    }

    private func block(_ markup: Markup, _ context: inout Context) {
        let line = markup.range?.lowerBound.line
        switch markup {
        case let heading as Heading:
            let sizes: [CGFloat] = [20, 17, 15, 13]
            let size = sizes[min(sizes.count, max(1, heading.level)) - 1]
            let font = NSFont.systemFont(ofSize: size, weight: heading.level <= 2 ? .bold : .semibold)
            paragraph(heading, font: font, context: &context, line: line, spacingBefore: heading.level <= 2 ? 6 : 3)
        case let paragraph as Paragraph:
            self.paragraph(paragraph, font: Self.bodyFont, context: &context, line: line)
        case let quote as BlockQuote:
            var inner = context
            inner.indent += 14
            inner.quoted = true
            blocks(quote, &inner)
            context.marker = inner.marker
        case let list as UnorderedList:
            listItems(Array(list.listItems), ordered: nil, &context)
        case let list as OrderedList:
            listItems(Array(list.listItems), ordered: Int(list.startIndex), &context)
        case let code as CodeBlock:
            fence(code, context: context, line: line ?? 1)
        case let table as Table:
            self.table(table, context: context, line: line)
        case is ThematicBreak:
            append(" \n", [.font: Self.bodyFont, .paragraphStyle: style(context, spacing: 8), .noteBlock: NoteBlock.rule.rawValue])
        case let html as HTMLBlock:
            code(html.rawHTML, context: context, line: line)
        default:
            if markup.childCount > 0 {
                blocks(markup, &context)
            } else {
                append(markup.format() + "\n", [.font: Self.bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style(context, spacing: 6)])
            }
        }
    }

    private func listItems(_ items: [ListItem], ordered start: Int?, _ context: inout Context) {
        for (index, item) in items.enumerated() {
            var inner = context
            let number = start.map { "\($0 + index)." }
            let checkbox = item.checkbox.map { $0 == .checked ? "☑" : "☐" }
            inner.marker = [number ?? (checkbox == nil ? "•" : nil), checkbox].compactMap { $0 }.joined(separator: " ")
            inner.markerWidth = start == nil ? (checkbox == nil ? 14 : 20) : 22
            inner.indent += inner.markerWidth + 4
            blocks(item, &inner)
        }
    }

    private func style(_ context: Context, spacing: CGFloat, before: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = context.indent
        style.headIndent = context.indent
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        style.lineHeightMultiple = 1.05
        return style
    }

    private func paragraph(_ markup: Markup, font: NSFont, context: inout Context, line: Int?, spacingBefore: CGFloat = 0) {
        let style = style(context, spacing: 6, before: spacingBefore)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: context.quoted ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: style,
        ]
        if let line { attributes[.noteMarkdownLine] = line }
        if context.quoted { attributes[.noteBlock] = NoteBlock.quote.rawValue }
        let start = out.length
        if let marker = context.marker {
            // Hanging marker: the marker sits in the indent, wrapped lines align with the text.
            style.firstLineHeadIndent = context.indent - context.markerWidth - 4
            style.tabStops = [NSTextTab(textAlignment: .left, location: context.indent)]
            append(marker + "\t", attributes.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 })
            context.marker = nil
        }
        inlines(markup, attributes, into: out)
        append("\n", attributes)
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
    }

    // MARK: Inlines

    private func inlines(_ markup: Markup, _ attributes: [NSAttributedString.Key: Any], into target: NSMutableAttributedString) {
        for child in markup.children { inline(child, attributes, into: target) }
    }

    private func inline(_ markup: Markup, _ attributes: [NSAttributedString.Key: Any], into target: NSMutableAttributedString) {
        var attributes = attributes
        let font = attributes[.font] as? NSFont ?? Self.bodyFont
        switch markup {
        case let text as Markdown.Text:
            target.append(NSAttributedString(string: text.string, attributes: attributes))
        case is Emphasis:
            attributes[.font] = Self.font(font, adding: .italic)
            inlines(markup, attributes, into: target)
        case is Strong:
            attributes[.font] = Self.font(font, adding: .bold)
            inlines(markup, attributes, into: target)
        case is Strikethrough:
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            inlines(markup, attributes, into: target)
        case let code as InlineCode:
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
            attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.25)
            let start = target.length
            target.append(NSAttributedString(string: code.code, attributes: attributes))
            linkReferences(in: code.code, at: start, of: target)
        case let link as Markdown.Link:
            if let destination = link.destination, let parsed = NoteLink(encoded: destination) {
                attributes[.noteLink] = parsed.encoded
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            inlines(markup, attributes, into: target)
        case let image as Markdown.Image:
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            target.append(NSAttributedString(string: "[image: \(image.plainText)]", attributes: attributes))
        case let html as InlineHTML:
            target.append(NSAttributedString(string: html.rawHTML, attributes: attributes))
        case is SoftBreak:
            target.append(NSAttributedString(string: " ", attributes: attributes))
        case is LineBreak:
            target.append(NSAttributedString(string: "\u{2028}", attributes: attributes))
        case let symbol as SymbolLink:
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
            target.append(NSAttributedString(string: symbol.destination ?? "", attributes: attributes))
        default:
            if markup.childCount > 0 {
                inlines(markup, attributes, into: target)
            } else {
                target.append(NSAttributedString(string: markup.format(), attributes: attributes))
            }
        }
    }

    public static func font(_ font: NSFont, adding trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)), size: font.pointSize) ?? font
    }

    /// `path:line` references in authored text open a code tile.
    private func linkReferences(in text: String, at offset: Int, of target: NSMutableAttributedString) {
        for reference in NoteReferences.find(in: text) {
            let range = NSRange(location: offset + reference.range.location, length: reference.range.length)
            target.addAttributes([
                .noteLink: NoteLink.code(path: reference.path, lines: reference.lines).encoded,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        }
    }

    // MARK: Tables

    private func table(_ table: Table, context: Context, line: Int?) {
        let header = Array(table.head.cells)
        let rows = [header] + table.body.rows.map { Array($0.cells) }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        let bold = Self.font(Self.bodyFont, adding: .bold)
        let rendered = rows.enumerated().map { index, cells in
            cells.map { cell -> NSAttributedString in
                let text = NSMutableAttributedString()
                inlines(cell, [.font: index == 0 ? bold : Self.bodyFont, .foregroundColor: NSColor.labelColor], into: text)
                return text
            }
        }
        var widths = [CGFloat](repeating: 0, count: columns)
        for cells in rendered {
            for (column, cell) in cells.enumerated() { widths[column] = max(widths[column], ceil(cell.size().width)) }
        }
        var stops: [NSTextTab] = []
        var x = context.indent + 4
        for width in widths.dropLast() {
            x += width + 18
            stops.append(NSTextTab(textAlignment: .left, location: x))
        }
        for (index, cells) in rendered.enumerated() {
            let style = style(context, spacing: index == rendered.count - 1 ? 8 : 2)
            style.firstLineHeadIndent = context.indent + 4
            style.tabStops = stops
            style.lineBreakMode = .byTruncatingTail
            let start = out.length
            for (column, cell) in cells.enumerated() {
                if column > 0 { append("\t", [.font: Self.bodyFont]) }
                out.append(cell)
            }
            append("\n", [.font: Self.bodyFont])
            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style]
            if index == 0 { attributes[.noteBlock] = NoteBlock.tableHeader.rawValue }
            if let line { attributes[.noteMarkdownLine] = line + index }
            out.addAttributes(attributes, range: NSRange(location: start, length: out.length - start))
        }
    }

    // MARK: Fences

    private func fence(_ block: CodeBlock, context: Context, line: Int) {
        let key = (block.language ?? "").trimmingCharacters(in: .whitespaces)
        let fence = NoteFence(info: key)
        let body = NoteSource.lines(of: block.code)
        switch fence.mode {
        case .free:
            rows(body.map { ($0, nil, NoteBlock.authored, nil) }, context: context, markdownLine: line + 1, numberWidth: 0, referenceLinks: true)
        case .excerpt, .propose:
            anchored(fence, excerpt: excerpts[key], body: body, context: context, line: line)
        }
    }

    private func anchored(_ fence: NoteFence, excerpt: NoteExcerpt?, body: [String], context: Context, line: Int) {
        let proposing = fence.mode == .propose
        guard let excerpt else {
            caption(fence, excerpt: nil, context: context, line: line)
            rows([("loading…", nil, .excerpt, nil)], context: context, markdownLine: line, numberWidth: 0, referenceLinks: false)
            return
        }
        caption(fence, excerpt: excerpt, context: context, line: line)
        guard let range = excerpt.range else {
            // Stale: what the excerpt last showed (or, for a proposal or a never-resolved excerpt,
            // the fence body), marked so nobody mistakes it for the file's current text.
            let fallback = proposing || excerpt.lines.isEmpty ? body : excerpt.lines
            rows(fallback.map { ($0, nil, proposing ? .authored : .excerpt, nil) }, context: context, markdownLine: line, numberWidth: 0, referenceLinks: false, dimmed: !proposing)
            return
        }
        let symbol = fence.symbol
        let width = String(range.end).count
        func row(_ number: Int) -> NoteCodeRow { NoteCodeRow(path: excerpt.path, line: number, symbol: symbol, commit: fence.commit) }
        if proposing, let diff = excerpt.diff {
            let lines = zip(diff, excerpt.proposalLines).map { entry, source -> (String, Int?, NoteBlock, NoteCodeRow?) in
                switch entry {
                case .same(_, _, let text): ("  " + text, source, .excerpt, row(source))
                case .removed(_, let text): ("- " + text, source, .removed, row(source))
                case .added(_, let text): ("+ " + text, nil, .added, row(source))
                }
            }
            rows(lines, context: context, markdownLine: line, numberWidth: width, referenceLinks: false)
        } else {
            let lines = excerpt.lines.enumerated().map { offset, text in (text, range.start + offset, NoteBlock.excerpt, Optional(row(range.start + offset))) }
            rows(lines, context: context, markdownLine: line, numberWidth: width, referenceLinks: false)
        }
    }

    /// `src/app.ts:10-40 · symbol X · @1a2b3c4 · moved from L10`, the path opening a code tile;
    /// a lost anchor says so in the caption.
    private func caption(_ fence: NoteFence, excerpt: NoteExcerpt?, context: Context, line: Int) {
        let style = style(context, spacing: 0, before: 2)
        style.firstLineHeadIndent = context.indent + NoteBlockFragment.inset + 4
        style.lineBreakMode = .byTruncatingMiddle
        let base: [NSAttributedString.Key: Any] = [
            .font: Self.captionFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            .noteBlock: NoteBlock.caption.rawValue, .noteMarkdownLine: line,
        ]
        let start = out.length
        if fence.mode == .propose { append("Proposed change · ", base.merging([.foregroundColor: NSColor.labelColor]) { $1 }) }
        let path = excerpt?.path ?? fence.path ?? ""
        let range = excerpt?.range ?? fence.lines
        let location = path + (range.map { $0.start == $0.end ? ":\($0.start)" : ":\($0.start)-\($0.end)" } ?? "")
        if !path.isEmpty {
            append(location, base.merging([.noteLink: NoteLink.code(path: path, lines: range).encoded, .foregroundColor: NSColor.linkColor]) { $1 })
        }
        var details: [String] = []
        if let symbol = fence.symbol { details.append("symbol \(symbol)") }
        if let commit = fence.commit { details.append("@\(commit)") }
        if case .relocated(let from)? = excerpt?.status { details.append("moved from L\(from)") }
        if !details.isEmpty { append(" · " + details.joined(separator: " · "), base) }
        if case .stale(let reason)? = excerpt?.status {
            append("  ⚠ stale: \(reason)", base.merging([.foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 10.5, weight: .bold)]) { $1 })
        }
        append("\n", base)
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
    }

    /// One paragraph per code row, so each row can carry its own band and source line.
    private func rows(_ rows: [(text: String, number: Int?, block: NoteBlock, row: NoteCodeRow?)], context: Context, markdownLine: Int, numberWidth: Int, referenceLinks: Bool, dimmed: Bool = false) {
        let shown = rows.prefix(Self.maxRows)
        for (index, row) in shown.enumerated() {
            let last = index == shown.count - 1 && rows.count <= Self.maxRows
            let style = style(context, spacing: last ? 8 : 0, before: index == 0 && numberWidth == 0 && row.block == .authored ? 2 : 0)
            style.firstLineHeadIndent = context.indent + NoteBlockFragment.inset + 4
            style.headIndent = style.firstLineHeadIndent
            style.lineBreakMode = .byTruncatingTail
            style.lineHeightMultiple = 1
            var attributes: [NSAttributedString.Key: Any] = [
                .font: Self.codeFont,
                .foregroundColor: dimmed ? NSColor.tertiaryLabelColor : NSColor.labelColor,
                .paragraphStyle: style,
                .noteBlock: row.block.rawValue,
                .noteMarkdownLine: markdownLine + (referenceLinks ? index : 0),
            ]
            if let codeRow = row.row { attributes[.noteCodeRow] = codeRow }
            if numberWidth > 0 {
                let number = row.number.map(String.init) ?? ""
                append(String(repeating: " ", count: max(0, numberWidth - number.count)) + number + "  ", attributes.merging([.foregroundColor: NSColor.tertiaryLabelColor]) { $1 })
            }
            let text = row.text.replacingOccurrences(of: "\t", with: "    ")
            let textStart = out.length
            append(text, attributes)
            if referenceLinks { linkReferences(in: text, at: textStart, of: out) }
            append("\n", attributes)
        }
        if rows.count > Self.maxRows {
            append("… \(rows.count - Self.maxRows) more lines\n", [.font: Self.captionFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style(context, spacing: 8)])
        }
    }

    private func code(_ text: String, context: Context, line: Int?) {
        rows(NoteSource.lines(of: text).map { ($0, nil, NoteBlock.authored, nil) }, context: context, markdownLine: line ?? 1, numberWidth: 0, referenceLinks: false)
    }

    private func append(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
        out.append(NSAttributedString(string: string, attributes: attributes))
    }
}
