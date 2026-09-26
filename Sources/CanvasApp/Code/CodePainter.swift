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

/// A position in the rows: a row index and a UTF-16 offset into that row's source line.
struct CodePosition: Comparable {
    var row: Int
    var offset: Int

    static func < (lhs: CodePosition, rhs: CodePosition) -> Bool {
        (lhs.row, lhs.offset) < (rhs.row, rhs.offset)
    }
}

/// Laid-out lines for the rows on screen, keyed by what they show. Each draw keeps only the rows
/// it drew, so the cache never outgrows the visible window.
@MainActor
final class CodeLineCache {
    enum Key: Hashable {
        case line(Int)
        case peek(Int)
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
/// document coordinates of a flipped context: row `i` spans
/// `verticalPadding + i × rowHeight ..< + rowHeight`. The live view, zoomed-out cards, and
/// offscreen renders all draw through this, straight from the model.
@MainActor
struct CodePainter {
    let document: CodeDocument
    let rows: CodeRows
    /// Displayed lines tinted as the object's `range`.
    var rangeLines: ClosedRange<Int>?
    /// Displayed lines an edit just changed, and the accent's current strength (0…1).
    var flash: (lines: [Range<Int>], strength: CGFloat)?
    var selection: (start: CodePosition, end: CodePosition)?

    var gutterWidth: CGFloat { CodeMetrics.gutterWidth(lineCount: max(document.text.lineCount, document.diff.old.lineCount)) }

    var contentSize: CGSize {
        CGSize(width: gutterWidth + CGFloat(document.longestLine) * CodeMetrics.charAdvance + CodeMetrics.trailingPadding,
               height: 2 * CodeMetrics.verticalPadding + CGFloat(max(1, rows.count)) * CodeMetrics.rowHeight)
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

    /// The source line a row shows: its text side, 1-based line, and syntax.
    func source(ofRow row: Int) -> (text: SideText, line: Int, syntax: SyntaxLines, key: CodeLineCache.Key)? {
        switch rows.row(row) {
        case .line(let line)?: (document.text, line, document.syntax, .line(line))
        case .peek(let old, _)?: (document.diff.old, old, document.oldSyntax, .peek(old))
        case nil: nil
        }
    }

    func text(ofRow row: Int) -> NSString {
        guard let source = source(ofRow: row) else { return "" }
        return (source.text.text as NSString).substring(with: source.text.range(ofLine: source.line)) as NSString
    }

    /// The row's line laid out: tabs expanded, highlighted. Colors resolve in the current
    /// drawing appearance.
    func makeLine(row: Int) -> CTLine {
        let raw = text(ofRow: row)
        let (display, map) = Self.expandTabs(raw)
        let string = NSMutableAttributedString(string: display, attributes: [.font: CodeTheme.font, .foregroundColor: NSColor.labelColor.cgColor])
        if let source = source(ofRow: row) {
            for run in source.syntax.runs(line: source.line) {
                let start = Int(run.start), end = min(Int(run.end), raw.length)
                guard start < end else { continue }
                let from = map?[start] ?? start, to = map?[end] ?? end
                string.addAttribute(.foregroundColor, value: CodeTheme.color(run.style).cgColor, range: NSRange(location: from, length: to - from))
            }
        }
        return CTLineCreateWithAttributedString(string)
    }

    /// Tabs become spaces up to the next tab stop; `map[i]` is the display offset of source
    /// offset `i` (nil when the line has no tabs).
    static func expandTabs(_ line: NSString) -> (String, [Int]?) {
        guard line.range(of: "\t").location != NSNotFound else { return (line as String, nil) }
        var out: [unichar] = []
        var map: [Int] = []
        map.reserveCapacity(line.length + 1)
        for index in 0..<line.length {
            map.append(out.count)
            let unit = line.character(at: index)
            if unit == 0x09 {
                let width = CodeMetrics.tabWidth - out.count % CodeMetrics.tabWidth
                out.append(contentsOf: repeatElement(0x20, count: width))
            } else {
                out.append(unit)
            }
        }
        map.append(out.count)
        return (String(utf16CodeUnits: out, count: out.count), map)
    }

    /// Source offset in a row nearest to `x` (document coordinates, text starting at
    /// `gutterWidth`).
    func offset(inRow row: Int, x: CGFloat, line: CTLine) -> Int {
        let display = CTLineGetStringIndexForPosition(line, CGPoint(x: x - gutterWidth, y: 0))
        let raw = text(ofRow: row)
        guard display != kCFNotFound else { return 0 }
        guard let map = Self.expandTabs(raw).1 else { return min(max(0, display), raw.length) }
        return map.lastIndex { $0 <= display } ?? 0
    }

    func x(ofOffset offset: Int, inRow row: Int, line: CTLine) -> CGFloat {
        let map = Self.expandTabs(text(ofRow: row)).1
        let display = map.map { $0[min(offset, $0.count - 1)] } ?? offset
        return gutterWidth + CTLineGetOffsetForStringIndex(line, display, nil)
    }

    // MARK: Drawing

    /// Draws the rows crossing `rect` (document coordinates). The gutter is pinned at
    /// `gutterX` (the visible left edge) so it stays put while the text scrolls sideways.
    func draw(in context: CGContext, rect: CGRect, gutterX: CGFloat, cache: CodeLineCache?) {
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        if let notice = document.notice {
            drawNotice(notice, in: rect)
            return
        }
        let visible = visibleRows(rect)
        let width = rect.maxX
        let selection = self.selection.flatMap { $0.start < $0.end ? $0 : nil }
        func line(_ row: Int) -> CTLine {
            guard let key = source(ofRow: row)?.key else { return makeLine(row: row) }
            return cache?.line(key) { makeLine(row: row) } ?? makeLine(row: row)
        }

        // Row tints, then selection, under the text.
        for row in visible {
            let frame = CGRect(x: rect.minX, y: Self.rowTop(row), width: width - rect.minX, height: CodeMetrics.rowHeight)
            let shown = rows.row(row)
            if case .peek? = shown {
                CodeTheme.peek.setFill()
                frame.fill()
            }
            if case .line(let number)? = shown {
                if let rangeLines, rangeLines.contains(number) {
                    CodeTheme.range.setFill()
                    frame.fill()
                }
                if let flash, flash.lines.contains(where: { $0.contains(number) }) {
                    CodeTheme.flash.withAlphaComponent(0.35 * flash.strength).setFill()
                    frame.fill()
                }
            }
            if let selection, selection.start.row <= row, row <= selection.end.row {
                let laid = line(row)
                let from = row == selection.start.row ? x(ofOffset: selection.start.offset, inRow: row, line: laid) : gutterWidth
                let to = row == selection.end.row ? x(ofOffset: selection.end.offset, inRow: row, line: laid) : width
                NSColor.selectedTextBackgroundColor.setFill()
                CGRect(x: from, y: frame.minY, width: max(0, to - from), height: frame.height).fill()
            }
        }

        // Text.
        context.saveGState()
        context.clip(to: CGRect(x: gutterX + gutterWidth, y: rect.minY, width: max(0, rect.maxX - gutterX - gutterWidth), height: rect.height))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for row in visible {
            context.textPosition = CGPoint(x: gutterWidth, y: Self.rowTop(row) + CodeMetrics.baseline)
            CTLineDraw(line(row), context)
        }
        context.restoreGState()
        cache?.commit()

        drawGutter(in: context, rows: visible, rect: rect, x: gutterX)
    }

    private func drawGutter(in context: CGContext, rows visible: Range<Int>, rect: CGRect, x: CGFloat) {
        let gutter = CGRect(x: x, y: rect.minY, width: gutterWidth, height: rect.height)
        NSColor.textBackgroundColor.setFill()
        gutter.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        CGRect(x: x + gutterWidth - CodeMetrics.textGap / 2, y: rect.minY, width: 0.5, height: rect.height).fill()
        let digits = CGFloat(CodeMetrics.lineNumberDigits(lineCount: max(document.text.lineCount, document.diff.old.lineCount)))
        let numbersRight = x + CodeMetrics.gutterLeading + digits * CodeMetrics.charAdvance
        let signX = numbersRight + CodeMetrics.signGap
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for row in visible {
            let top = Self.rowTop(row)
            let number: Int
            let color: NSColor
            switch rows.row(row) {
            case .line(let line)?:
                number = line
                color = rangeLines?.contains(line) == true ? .secondaryLabelColor : .tertiaryLabelColor
                if let sign = document.signs.first(where: { $0.lines.contains(line) }) {
                    (sign.kind == .added ? CodeTheme.added : CodeTheme.modified).setFill()
                    CGRect(x: signX, y: top, width: CodeMetrics.signWidth - 1, height: CodeMetrics.rowHeight).fill()
                }
            case .peek(let old, _)?:
                number = old
                color = CodeTheme.deleted.withAlphaComponent(0.8)
                CodeTheme.deleted.setFill()
                CGRect(x: signX, y: top, width: CodeMetrics.signWidth - 1, height: CodeMetrics.rowHeight).fill()
            case nil:
                continue
            }
            let label = NSAttributedString(string: String(number), attributes: [.font: CodeTheme.font, .foregroundColor: color.cgColor])
            let laid = CTLineCreateWithAttributedString(label)
            context.textPosition = CGPoint(x: numbersRight - CGFloat(String(number).count) * CodeMetrics.charAdvance, y: top + CodeMetrics.baseline)
            CTLineDraw(laid, context)
        }
        context.restoreGState()
        // Deletion wedges sit on the edge between two lines; a peeked deletion shows its rows.
        let peeked = rows.peekedSigns
        for (index, sign) in document.signs.enumerated() where sign.kind == .deleted && !peeked.contains(index) {
            let line = sign.lines.lowerBound
            let edge = line <= document.text.lineCount ? Self.rowTop(rows.index(ofLine: line)) : Self.rowTop(rows.index(ofLine: document.text.lineCount) + 1)
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

    /// Sign under a gutter point: the bar of the row, or a deletion wedge within a few points of
    /// the row edge it sits on.
    func sign(atY y: CGFloat) -> Int? {
        let row = Self.row(atY: y)
        if case .peek(_, let sign)? = rows.row(row) { return sign }
        let peeked = rows.peekedSigns
        for (index, sign) in document.signs.enumerated() where sign.kind == .deleted && !peeked.contains(index) {
            let line = sign.lines.lowerBound
            let edge = line <= document.text.lineCount ? Self.rowTop(rows.index(ofLine: line)) : Self.rowTop(rows.index(ofLine: document.text.lineCount) + 1)
            if abs(edge - y) <= 5 { return index }
        }
        if case .line(let line)? = rows.row(row) {
            return document.signs.firstIndex { $0.lines.contains(line) }
        }
        return nil
    }
}
