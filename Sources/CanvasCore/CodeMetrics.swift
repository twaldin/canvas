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

    /// The tile chrome's title bar (every tile type).
    public static let titleHeight: CGFloat = 26
    /// Code header: diff base, change navigation, status and warnings.
    public static let headerHeight: CGFloat = 26
    /// The one-line `caption` strip under the header (truncated, never wraps).
    public static let captionHeight: CGFloat = 20
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
        let width = gutterWidth(lineCount: 1) + CGFloat(max(0, longestLine)) * charAdvance + trailingPadding
        let height = chromeHeight(caption: caption) + 2 * verticalPadding + CGFloat(max(1, lines)) * rowHeight
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
}
