import CoreGraphics

/// Geometry of a code tile in points, shared by the renderer (which must obey it) and layout
/// (`object.measure`, `size: "fit"`). Rows are a fixed height; text is the system monospaced
/// font at `fontSize`, so every character (after expanding tabs to `tabWidth` columns) is
/// `charAdvance` wide.
///
/// The object's frame, top to bottom: the tile title bar, the code header, the optional caption
/// strip, the follow history strip (follow tiles only), then `verticalPadding`, the rows, and
/// `verticalPadding` again. Left to right: the gutter (line numbers and change signs), the
/// text, `trailingPadding`.
public enum CodeMetrics {
    public static let fontSize: CGFloat = 12
    /// Advance of every glyph of `NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)`.
    public static let charAdvance: CGFloat = 7.41796875
    public static let rowHeight: CGFloat = 16
    /// Baseline from the top of a row.
    public static let baseline: CGFloat = 12
    public static let tabWidth = 4

    /// The tile chrome's title bar (every tile type), at the top of the frame.
    public static let titleHeight = CGFloat(RenderMath.tileTitleHeight)
    /// Code header: diff base, change navigation, status and warnings.
    public static let headerHeight: CGFloat = 26
    /// The one-line `caption` strip under the header (truncated, never wraps).
    public static let captionHeight: CGFloat = 20
    /// Caption text's inset from the tile's left and right edges.
    public static let captionInset: CGFloat = 8
    /// Recent-locations strip under the header of follow tiles.
    public static let historyHeight: CGFloat = 22
    /// Above the first row and below the last.
    public static let verticalPadding: CGFloat = 4

    /// Line numbers get at least this many digits, so tiles over files of up to 9,999 lines
    /// share one gutter width.
    public static let minLineNumberDigits = 4
    /// Left of the line numbers.
    public static let gutterLeading: CGFloat = 4
    /// Between the line numbers and the change-sign column.
    public static let signGap: CGFloat = 5
    /// The change-sign column (added/modified bars, deleted wedges).
    public static let signWidth: CGFloat = 4
    /// Between the sign column and the text.
    public static let textGap: CGFloat = 7
    public static let trailingPadding: CGFloat = 12
    /// Narrowest frame the header controls fit in.
    public static let minWidth: CGFloat = 280

    public static func lineNumberDigits(lineCount: Int) -> Int {
        max(minLineNumberDigits, String(max(1, lineCount)).count)
    }

    /// Width of everything left of the text for a file of `lineCount` lines.
    public static func gutterWidth(lineCount: Int) -> CGFloat {
        (gutterLeading + CGFloat(lineNumberDigits(lineCount: lineCount)) * charAdvance + signGap + signWidth + textGap).rounded(.up)
    }

    /// Height above the first row's padding, inside the object's frame.
    public static func chromeHeight(caption: Bool, history: Bool = false) -> CGFloat {
        titleHeight + headerHeight + (caption ? captionHeight : 0) + (history ? historyHeight : 0)
    }

    /// Full object frame that shows `lines` rows of at most `longestLine` columns (tabs
    /// expanded) without scrolling, for files of up to 9,999 lines.
    public static func size(lines: Int, longestLine: Int, caption: Bool) -> CGSize {
        var size = content(rows: lines, longestLine: longestLine, gutterWidth: gutterWidth(lineCount: 1), headerHeight: chromeHeight(caption: caption) - titleHeight)
        size.height += titleHeight
        return size
    }

    /// A code tile's content (its body, below the title bar) showing `rows` rows of at most
    /// `longestLine` columns beside a `gutterWidth` gutter, under header strips `headerHeight`
    /// tall: what `view.render` reports as its `contentSize`.
    public static func content(rows: Int, longestLine: Int, gutterWidth: CGFloat, headerHeight: CGFloat) -> CGSize {
        let width = gutterWidth + CGFloat(max(0, longestLine)) * charAdvance + trailingPadding
        let height = headerHeight + 2 * verticalPadding + CGFloat(max(1, rows)) * rowHeight
        return CGSize(width: max(minWidth, width.rounded(.up)), height: height.rounded(.up))
    }

    /// Columns a line occupies with tabs expanded to the next multiple of `tabWidth`.
    public static func columns(_ line: some StringProtocol) -> Int {
        var column = 0
        for unit in line.utf16 {
            column = unit == 0x09 ? (column / tabWidth + 1) * tabWidth : column + 1
        }
        return column
    }

    // MARK: Scroll rule and line anchors

    /// Rows of context shown above a range when the viewport has room for them and the range.
    public static let rangeContext = 3

    /// Scroll offset (points from the top of the rows, before `verticalPadding`) that shows the
    /// range starting at visual row `row` and `count` rows long in a rows viewport `viewport`
    /// points tall: the range's first row near the top with up to `rangeContext` rows of context
    /// above it, fewer when the viewport can't show that context and all `count` rows too (a
    /// tile sized to fit its range shows exactly the range). Clamped to the content when
    /// `totalRows` is known.
    public static func scrollOffset(toRow row: Int, count: Int, viewport: CGFloat, totalRows: Int?) -> CGFloat {
        let visible = Int(((viewport - verticalPadding) / rowHeight).rounded(.down))
        let context = max(0, min(rangeContext, visible - count))
        var offset = CGFloat(max(0, row - context)) * rowHeight
        if let totalRows {
            let content = 2 * verticalPadding + CGFloat(max(1, totalRows)) * rowHeight
            offset = min(offset, max(0, content - viewport))
        }
        return max(0, offset)
    }

    /// Where an arrow bound to `line` attaches on a code tile, in points from the top of its
    /// frame: the middle of the line's first visual row (`rows`, or one row per line), with the
    /// rows scrolled by `scroll` below `rowsTop`, clamped into the rows viewport
    /// (`rowsTop`…`frameHeight`), so a line scrolled out of view pins the end to the top or
    /// bottom edge of the code.
    public static func lineY(line: Int, rows: CodeRows?, scroll: CGFloat, rowsTop: CGFloat, frameHeight: CGFloat) -> CGFloat {
        let row = rows?.index(ofLine: line) ?? max(0, line - 1)
        let y = rowsTop + verticalPadding + CGFloat(row) * rowHeight - scroll + rowHeight / 2
        return min(max(y, rowsTop), max(rowsTop, frameHeight))
    }

    /// `lineY` for a code tile at `frame` with `props` as it shows them freshly aimed: scrolled to
    /// `props.range` by `scrollOffset`. Canvas y. `rows` nil: one row per line, content length
    /// unknown. Live tiles use their real scroll instead (the user may have scrolled).
    public static func lineY(line: Int, frame: Frame, props: JSONValue, rows: CodeRows?) -> CGFloat {
        let caption = props["caption"]?.string.map { !$0.isEmpty } ?? false
        let history = props["followOf"]?.string != nil && !(props["history"]?.array?.isEmpty ?? true)
        let rowsTop = chromeHeight(caption: caption, history: history)
        let viewport = max(0, CGFloat(frame.h) - rowsTop)
        var scroll: CGFloat = 0
        if let start = props["range"]?["start"]?.int {
            let end = max(start, props["range"]?["end"]?.int ?? start)
            let first = rows?.index(ofLine: start) ?? max(0, start - 1)
            let last = rows?.index(ofLine: end) ?? max(0, end - 1)
            scroll = scrollOffset(toRow: first, count: last - first + 1, viewport: viewport, totalRows: rows?.count)
        }
        return CGFloat(frame.y) + lineY(line: line, rows: rows, scroll: scroll, rowsTop: rowsTop, frameHeight: CGFloat(frame.h))
    }
}
