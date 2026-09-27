import AppKit
import CanvasCore

/// Colors for code tiles; system colors so light and dark appearances both read. Resolve them
/// inside the drawing appearance (`performAsCurrentDrawingAppearance`).
enum CodeTheme {
    @MainActor static let font = NSFont.monospacedSystemFont(ofSize: CodeMetrics.fontSize, weight: .regular)
    static var peek: NSColor { NSColor.systemRed.withAlphaComponent(0.14) }
    static var range: NSColor { NSColor.systemYellow.withAlphaComponent(0.22) }
    static var flash: NSColor { NSColor.controlAccentColor }
    static var added: NSColor { .systemGreen }
    static var modified: NSColor { .systemBlue }
    static var deleted: NSColor { .systemRed }

    static func color(_ style: SyntaxStyle) -> NSColor {
        switch style {
        case .keyword: .systemPink
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .number: .systemPurple
        case .type: .systemTeal
        case .function: .systemIndigo
        case .property: .systemBrown
        case .variable: .labelColor
        case .builtin: .systemPurple
        case .tag: .systemBlue
        case .punctuation: .secondaryLabelColor
        }
    }
}

/// Laid-out rows on screen, keyed by what they show. Each draw keeps only the rows it drew, so
/// the cache never outgrows the visible window.
@MainActor
final class CodeLineCache {
    struct Key: Hashable {
        var row: CodeRows.Row
        var part: Int
        /// Wrapping at another width lays the same part out differently.
        var columns: Int?
    }

    private(set) var lines: [Key: CTLine] = [:]
    private var drawn: [Key: CTLine] = [:]

    func line(_ key: Key, make: () -> CTLine) -> CTLine {
        if let line = drawn[key] ?? lines[key] {
            drawn[key] = line
            return line
        }
        let line = make()
        drawn[key] = line
        return line
    }

    /// Ends a draw pass: rows that weren't drawn are dropped.
    func commit() {
        lines = drawn
        drawn = [:]
    }

    func removeAll() {
        lines = [:]
        drawn = [:]
    }
}

/// Draws a code document's rows (gutter, change signs, peek rows, tints, highlighted text) in
/// document coordinates of a flipped context: visual row `i` spans
/// `verticalPadding + i × rowHeight ..< + rowHeight`. Rows are soft-wrapped at `rows.columns`:
/// a continuation row has no line number (a faint hook instead), its line's sign, tints, and
/// highlighting, and its text indented by the segment's indent. The live view, zoomed-out
/// cards, and offscreen renders all draw through this, straight from the model.
@MainActor
struct CodePainter {
    let document: CodeDocument
    let rows: CodeRows
    /// Displayed lines of the object's `range`: tinted while rows outside it are visible
    /// (`CodeMetrics.tintsRange`).
    var rangeLines: ClosedRange<Int>?
    /// Displayed lines an edit just changed, and the accent's current strength (0…1).
    var flash: (lines: [Range<Int>], strength: CGFloat)?
    var selection: (start: CodeRows.Position, end: CodeRows.Position)?

    var gutterWidth: CGFloat { document.gutterWidth }

    /// Height of all rows; there is no horizontal extent beyond the view (rows wrap).
    var contentHeight: CGFloat {
        2 * CodeMetrics.verticalPadding + CGFloat(max(1, rows.count)) * CodeMetrics.rowHeight
    }

    static func rowTop(_ row: Int) -> CGFloat {
        CodeMetrics.verticalPadding + CGFloat(row) * CodeMetrics.rowHeight
    }

    static func row(atY y: CGFloat) -> Int {
        Int(((y - CodeMetrics.verticalPadding) / CodeMetrics.rowHeight).rounded(.down))
    }

    /// Rows intersecting a vertical span.
    func visibleRows(_ rect: CGRect) -> Range<Int> {
        let first = max(0, Self.row(atY: rect.minY))
        let last = min(rows.count, Self.row(atY: rect.maxY) + 1)
        return first..<max(first, last)
    }

    // MARK: Row text

    func text(ofEntry entry: Int) -> NSString {
        guard let row = rows.entryRow(entry) else { return "" }
        return document.text(of: row) as NSString
    }

    /// Left edge of a row's text: continuation rows are indented.
    func textX(_ segment: CodeRows.Segment) -> CGFloat {
        gutterWidth + CGFloat(segment.indent) * CodeMetrics.charAdvance
    }

    /// A visual row laid out: its slice of the line, tabs expanded, highlighted. Colors resolve
    /// in the current drawing appearance.
    func makeLine(_ segment: CodeRows.Segment) -> CTLine {
        let text = document.rowText(segment)
        let string = NSMutableAttributedString(string: text.display, attributes: [.font: CodeTheme.font, .foregroundColor: NSColor.labelColor.cgColor])
        let source = document.source(of: segment.row)
        for run in source.syntax.runs(line: source.line) {
            let start = max(Int(run.start), text.start), end = min(Int(run.end), text.end)
            guard start < end else { continue }
            let from = text.display(ofOffset: start), to = text.display(ofOffset: end)
            string.addAttribute(.foregroundColor, value: CodeTheme.color(run.style).cgColor, range: NSRange(location: from, length: to - from))
        }
        return CTLineCreateWithAttributedString(string)
    }

    func line(_ segment: CodeRows.Segment, cache: CodeLineCache?) -> CTLine {
        let key = CodeLineCache.Key(row: segment.row, part: segment.part, columns: rows.columns)
        return cache?.line(key) { makeLine(segment) } ?? makeLine(segment)
    }

    /// Line offset in a visual row nearest to `x` (document coordinates).
    func offset(in segment: CodeRows.Segment, x: CGFloat, line: CTLine) -> Int {
        let text = document.rowText(segment)
        let display = CTLineGetStringIndexForPosition(line, CGPoint(x: x - textX(segment), y: 0))
        guard display != kCFNotFound else { return text.start }
        return text.offset(ofDisplay: display)
    }

    /// X of a line offset within a visual row (clamped to the row's slice).
    func x(ofOffset offset: Int, in segment: CodeRows.Segment, line: CTLine) -> CGFloat {
        textX(segment) + CTLineGetOffsetForStringIndex(line, document.rowText(segment).display(ofOffset: offset), nil)
    }

    /// Selected span of a visual row: from/to x, `to` nil when the selection runs past the row.
    private func selected(_ segment: CodeRows.Segment, _ selection: (start: CodeRows.Position, end: CodeRows.Position), line: CTLine) -> (from: CGFloat, to: CGFloat?)? {
        guard selection.start.entry <= segment.entry, segment.entry <= selection.end.entry else { return nil }
        let start = segment.start, end = segment.end
        let lower = segment.entry == selection.start.entry ? selection.start.offset : Int.min
        let upper = segment.entry == selection.end.entry ? selection.end.offset : Int.max
        if let end, lower >= end { return nil }
        if segment.isContinuation, upper <= start { return nil }
        let from = lower <= start ? textX(segment) : x(ofOffset: lower, in: segment, line: line)
        // Past this row: the rest of the line on a row that continues, or the line break.
        let past = end.map { upper > $0 } ?? (upper == Int.max)
        return (from, past ? nil : x(ofOffset: upper, in: segment, line: line))
    }

    // MARK: Drawing

    /// Draws the rows crossing `rect` (document coordinates). Rows never paint into the
    /// `verticalPadding` bands at the top and bottom of `rect`, so a tile scrolled to its range
    /// shows none of the lines around it (a fit tile shows exactly it). `rect` is the viewport:
    /// the range is tinted only when it shows rows outside the range.
    func draw(in context: CGContext, rect: CGRect, cache: CodeLineCache?) {
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        if let notice = document.notice {
            drawNotice(notice, in: rect)
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect.insetBy(dx: 0, dy: min(CodeMetrics.verticalPadding, rect.height / 2)))
        let visible = visibleRows(rect)
        let segments = visible.map { rows.segment($0) }
        let width = rect.maxX
        let selection = self.selection.flatMap { $0.start < $0.end ? $0 : nil }
        let tinted = rangeLines.flatMap { lines -> ClosedRange<Int>? in
            let first = rows.index(ofLine: lines.lowerBound)
            let range = first..<max(first, rows.rows(ofLine: lines.upperBound).upperBound)
            return CodeMetrics.tintsRange(range, scroll: rect.minY, viewport: rect.height, totalRows: rows.count) ? lines : nil
        }

        // Row tints, then selection, under the text.
        for (row, segment) in zip(visible, segments) {
            guard let segment else { continue }
            let frame = CGRect(x: rect.minX, y: Self.rowTop(row), width: width - rect.minX, height: CodeMetrics.rowHeight)
            switch segment.row {
            case .peek:
                CodeTheme.peek.setFill()
                frame.fill()
            case .line(let number):
                if let tinted, tinted.contains(number) {
                    CodeTheme.range.setFill()
                    frame.fill()
                }
                if let flash, flash.lines.contains(where: { $0.contains(number) }) {
                    CodeTheme.flash.withAlphaComponent(0.35 * flash.strength).setFill()
                    frame.fill()
                }
            }
            if let selection, let span = selected(segment, selection, line: line(segment, cache: cache)) {
                NSColor.selectedTextBackgroundColor.setFill()
                let to = span.to ?? width
                CGRect(x: span.from, y: frame.minY, width: max(0, to - span.from), height: frame.height).fill()
            }
        }

        // Text.
        context.saveGState()
        context.clip(to: CGRect(x: gutterWidth, y: rect.minY, width: max(0, rect.maxX - gutterWidth), height: rect.height))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (row, segment) in zip(visible, segments) {
            guard let segment else { continue }
            context.textPosition = CGPoint(x: textX(segment), y: Self.rowTop(row) + CodeMetrics.baseline)
            CTLineDraw(line(segment, cache: cache), context)
        }
        context.restoreGState()
        cache?.commit()

        drawGutter(in: context, rows: visible, segments: segments, rect: rect, tinted: tinted)
    }

    private func drawGutter(in context: CGContext, rows visible: Range<Int>, segments: [CodeRows.Segment?], rect: CGRect, tinted: ClosedRange<Int>?) {
        let gutter = CGRect(x: 0, y: rect.minY, width: gutterWidth, height: rect.height)
        NSColor.textBackgroundColor.setFill()
        gutter.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        CGRect(x: gutterWidth - CodeMetrics.textGap / 2, y: rect.minY, width: 0.5, height: rect.height).fill()
        let digits = CGFloat(CodeMetrics.lineNumberDigits(lineCount: document.gutterLineCount))
        let numbersRight = CodeMetrics.gutterLeading + digits * CodeMetrics.charAdvance
        let signX = numbersRight + CodeMetrics.signGap
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (row, segment) in zip(visible, segments) {
            guard let segment else { continue }
            let top = Self.rowTop(row)
            let number: Int
            let color: NSColor
            switch segment.row {
            case .line(let line):
                number = line
                color = tinted?.contains(line) == true ? .secondaryLabelColor : .tertiaryLabelColor
                if let sign = document.signs.first(where: { $0.lines.contains(line) }) {
                    (sign.kind == .added ? CodeTheme.added : CodeTheme.modified).setFill()
                    CGRect(x: signX, y: top, width: CodeMetrics.signWidth - 1, height: CodeMetrics.rowHeight).fill()
                }
            case .peek(let old, _):
                number = old
                color = CodeTheme.deleted.withAlphaComponent(0.8)
                CodeTheme.deleted.setFill()
                CGRect(x: signX, y: top, width: CodeMetrics.signWidth - 1, height: CodeMetrics.rowHeight).fill()
            }
            // Continuation rows: a faint hook where the number would be.
            let label = segment.isContinuation ? "↪" : String(number)
            let attributes: [NSAttributedString.Key: Any] = [.font: CodeTheme.font, .foregroundColor: (segment.isContinuation ? NSColor.quaternaryLabelColor : color).cgColor]
            let laid = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
            let labelWidth = segment.isContinuation ? CTLineGetTypographicBounds(laid, nil, nil, nil) : CGFloat(label.count) * CodeMetrics.charAdvance
            context.textPosition = CGPoint(x: numbersRight - labelWidth, y: top + CodeMetrics.baseline)
            CTLineDraw(laid, context)
        }
        context.restoreGState()
        // Deletion wedges sit on the edge between two lines; a peeked deletion shows its rows.
        let peeked = rows.peekedSigns
        for (index, sign) in document.signs.enumerated() where sign.kind == .deleted && !peeked.contains(index) {
            let edge = Self.rowTop(rows.edgeRow(ofLine: sign.lines.lowerBound))
            guard edge >= rect.minY - 6, edge <= rect.maxY + 6 else { continue }
            let wedge = NSBezierPath()
            wedge.move(to: CGPoint(x: signX - 1, y: edge - 4.5))
            wedge.line(to: CGPoint(x: signX + CodeMetrics.signWidth + 3, y: edge))
            wedge.line(to: CGPoint(x: signX - 1, y: edge + 4.5))
            wedge.close()
            CodeTheme.deleted.setFill()
            wedge.fill()
        }
    }

    private func drawNotice(_ notice: String, in rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        let size = (notice as NSString).size(withAttributes: attributes)
        (notice as NSString).draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + max(12, min(40, (rect.height - size.height) / 2))), withAttributes: attributes)
    }

    // MARK: Hit testing

    /// Sign under a gutter point: the bar of the row (any of a wrapped line's rows), or a
    /// deletion wedge within a few points of the row edge it sits on.
    func sign(atY y: CGFloat) -> Int? {
        let row = rows.row(Self.row(atY: y))
        if case .peek(_, let sign)? = row { return sign }
        let peeked = rows.peekedSigns
        for (index, sign) in document.signs.enumerated() where sign.kind == .deleted && !peeked.contains(index) {
            if abs(Self.rowTop(rows.edgeRow(ofLine: sign.lines.lowerBound)) - y) <= 5 { return index }
        }
        if case .line(let line)? = row {
            return document.signs.firstIndex { $0.lines.contains(line) }
        }
        return nil
    }
}
