import Foundation

/// Geometry of a changes tile: a header strip, then rows (the file list, then per file its
/// header, its hunks' headers, their unified-diff lines). Lines use the code tile's font and row
/// height (`CodeMetrics`) and soft-wrap like code tiles (`CodeMetrics.wrap`: continuation rows
/// indented by the line's indentation plus 2 columns). `object.measure` and `size: "fit"` use
/// the same numbers.
public enum ChangesMetrics {
    public static let headerHeight: CGFloat = 26
    public static let listHeight: CGFloat = 24
    public static let listedHeight: CGFloat = 18
    public static let fileHeight: CGFloat = 28
    public static let hunkHeight: CGFloat = 22
    public static let lineHeight = CodeMetrics.rowHeight
    public static let noticeHeight: CGFloat = 22
    public static let messageHeight: CGFloat = 44
    public static let bottomPadding: CGFloat = 8
    public static let gutterLeading: CGFloat = 6
    public static let numberGap: CGFloat = 8
    public static let signWidth: CGFloat = 14
    public static let trailingPadding: CGFloat = 12
    /// Width of each drawn button in a file or hunk header ("Stage", "Discard").
    public static let buttonWidth: CGFloat = 58
    public static let buttonGap: CGFloat = 6
    /// The file header's Viewed check, left of its buttons.
    public static let viewedWidth: CGFloat = 70
    /// The header strip's filter field, at its right edge.
    public static let filterWidth: CGFloat = 170
    public static let minWidth: CGFloat = 480
    public static let defaultFitWidth: CGFloat = 960
    /// Tallest frame `size: "fit"` gives, title bar included; more scrolls.
    public static let maxFitHeight: CGFloat = 4000

    /// Digits of each line-number column: at least 4, like code tiles.
    public static func digits(_ set: ChangeSet) -> Int {
        CodeMetrics.lineNumberDigits(lineCount: set.files.reduce(0) { max($0, $1.old.lineCount, $1.new.lineCount) })
    }

    /// Everything left of a line's text: old and new line numbers and the +/− sign.
    public static func gutterWidth(digits: Int) -> CGFloat {
        gutterLeading + 2 * CGFloat(digits) * CodeMetrics.charAdvance + numberGap + signWidth
    }

    /// Text columns a body `width` points wide shows before a line wraps; at least 8.
    public static func textColumns(width: CGFloat, digits: Int) -> Int {
        max(8, Int(((width - gutterWidth(digits: digits) - trailingPadding) / CodeMetrics.charAdvance + 0.001).rounded(.down)))
    }

    /// Files a tile starts with folded: deleted files (their whole text is rarely what needs
    /// review) and those marked Viewed for their current diff (`props.viewed`).
    public static func folded(_ set: ChangeSet, viewed: JSONValue?) -> Set<String> {
        Set(set.files.filter { $0.status == .deleted || $0.isViewed(in: viewed) }.map(\.boardPath))
    }

    /// The frame (title bar included) that shows every row of `set` without scrolling (deleted
    /// and viewed files folded, as the tile starts), as wide as its longest line up to
    /// `maxWidth` (at least `minWidth`), lines wrapped at that width, at most `maxFitHeight` tall.
    public static func fit(_ set: ChangeSet, maxWidth: CGFloat?, viewed: JSONValue? = nil) -> CGSize {
        let folded = folded(set, viewed: viewed)
        var longest = 0
        for file in set.files where !folded.contains(file.boardPath) {
            for hunk in file.hunks {
                for line in hunk.lines {
                    let text = line.kind == .removed ? file.old : file.new
                    guard let number = line.kind == .removed ? line.old : line.new, number <= text.lineCount else { continue }
                    longest = max(longest, CodeMetrics.columns(text.line(number)))
                }
            }
        }
        let digits = digits(set)
        let natural = gutterWidth(digits: digits) + CGFloat(longest) * CodeMetrics.charAdvance + trailingPadding
        let width = min(max(natural.rounded(.up), minWidth), max(minWidth, (maxWidth ?? defaultFitWidth).rounded(.down)))
        let rows = ChangeRows(set, collapsed: folded, columns: textColumns(width: width, digits: digits))
        let height = CodeMetrics.titleHeight + headerHeight + rows.height + bottomPadding
        return CGSize(width: width, height: min(height.rounded(.up), maxFitHeight))
    }
}

/// The rows a changes tile draws, top to bottom, with each row's top (below the header strip).
public struct ChangeRows: Equatable, Sendable {
    public enum Row: Equatable, Sendable {
        /// The file list's heading (more than one file): how many, and whether it is open.
        case list(open: Bool)
        /// A file in the list: a click jumps to it.
        case listed(Int)
        case file(Int)
        case hunk(file: Int, hunk: Int)
        case line(file: Int, hunk: Int, line: Int)
        /// Why a file has no hunks (binary, too large…).
        case notice(file: Int)
        /// Nothing to list, and why.
        case message(String)
        /// Files past `ChangeSet.maxFiles`.
        case omitted(Int)

        /// The file a row is part of (its header, list entry, hunks, lines, notice).
        public var file: Int? {
            switch self {
            case .listed(let file), .file(let file), .hunk(let file, _), .line(let file, _, _), .notice(let file): file
            case .list, .message, .omitted: nil
            }
        }
    }

    /// How a wrapped line breaks (`CodeMetrics.wrap`): UTF-16 offsets of its continuation rows
    /// and their indent in columns.
    public struct Wrap: Equatable, Sendable {
        public var breaks: [Int]
        public var indent: Int
    }

    public let rows: [Row]
    public let tops: [CGFloat]
    public let height: CGFloat
    /// Wrapped lines by row index; every other line is one row.
    public let wraps: [Int: Wrap]
    /// Files shown (the filter's matches), in order.
    public let shown: [Int]
    /// Text columns lines wrap at; nil: they don't.
    public let columns: Int?

    /// `collapsed`: board paths of files shown as their header only. `columns`: text columns
    /// lines wrap at (nil: never). `filter`: only files whose board path contains it (any case).
    /// `listOpen`: the file list shows its files.
    public init(_ set: ChangeSet, collapsed: Set<String>, columns: Int? = nil, filter: String = "", listOpen: Bool = true) {
        var rows: [Row] = []
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let shown = set.files.indices.filter { needle.isEmpty || set.files[$0].boardPath.range(of: needle, options: .caseInsensitive) != nil }
        if let notice = set.notice {
            rows.append(.message(notice))
        } else if set.files.isEmpty {
            rows.append(.message("No changes against \(set.baseLabel.isEmpty ? "the base" : set.baseLabel)"))
        } else if shown.isEmpty {
            rows.append(.message("No changed file matches “\(needle)”"))
        }
        if set.files.count > 1 {
            rows.append(.list(open: listOpen))
            if listOpen { rows.append(contentsOf: shown.map(Row.listed)) }
        }
        for index in shown {
            let file = set.files[index]
            rows.append(.file(index))
            guard !collapsed.contains(file.boardPath) else { continue }
            if file.notice != nil {
                rows.append(.notice(file: index))
                continue
            }
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                rows.append(.hunk(file: index, hunk: hunkIndex))
                for line in hunk.lines.indices { rows.append(.line(file: index, hunk: hunkIndex, line: line)) }
            }
        }
        if set.omitted > 0 { rows.append(.omitted(set.omitted)) }
        var tops: [CGFloat] = []
        var wraps: [Int: Wrap] = [:]
        tops.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            tops.append(y)
            if let columns, case .line(let file, let hunk, let line) = row, let wrap = Self.wrap(set, file: file, hunk: hunk, line: line, columns: columns) {
                wraps[index] = wrap
                y += CGFloat(wrap.breaks.count + 1) * ChangesMetrics.lineHeight
            } else {
                y += Self.height(of: row)
            }
        }
        self.rows = rows
        self.tops = tops
        self.wraps = wraps
        self.shown = shown
        self.columns = columns
        height = y
    }

    /// How a diff line wraps at `columns`, nil when it fits.
    static func wrap(_ set: ChangeSet, file: Int, hunk: Int, line: Int, columns: Int) -> Wrap? {
        let changed = set.files[file], row = changed.hunks[hunk].lines[line]
        let text = row.kind == .removed ? changed.old : changed.new
        guard let number = row.kind == .removed ? row.old : row.new, number >= 1, number <= text.lineCount else { return nil }
        let range = text.range(ofLine: number)
        // A line of at most columns/4 units fits whatever its tabs and wide characters.
        guard range.length > columns / 4 else { return nil }
        let units = (text.text as NSString).substring(with: range).utf16
        let wrap = CodeMetrics.wrap(units, columns: columns)
        return wrap.breaks.isEmpty ? nil : Wrap(breaks: wrap.breaks, indent: wrap.indent)
    }

    /// Height of an unwrapped row.
    public static func height(of row: Row) -> CGFloat {
        switch row {
        case .list: ChangesMetrics.listHeight
        case .listed: ChangesMetrics.listedHeight
        case .file: ChangesMetrics.fileHeight
        case .hunk: ChangesMetrics.hunkHeight
        case .line: ChangesMetrics.lineHeight
        case .notice, .omitted: ChangesMetrics.noticeHeight
        case .message: ChangesMetrics.messageHeight
        }
    }

    public func height(ofRow index: Int) -> CGFloat {
        (index + 1 < tops.count ? tops[index + 1] : height) - tops[index]
    }

    /// The row at `y` (row coordinates: 0 at the first row's top), nil past the last.
    public func index(atY y: CGFloat) -> Int? {
        guard y >= 0, y < height, !rows.isEmpty else { return nil }
        var low = 0, high = rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if tops[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Rows crossing a vertical span.
    public func visible(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        guard let first = index(atY: max(0, minY)) else { return 0..<0 }
        var last = first
        while last + 1 < rows.count, tops[last + 1] < maxY { last += 1 }
        return first..<(last + 1)
    }

    public func index(ofHunk file: Int, _ hunk: Int) -> Int? {
        rows.firstIndex(of: .hunk(file: file, hunk: hunk))
    }

    public func index(ofFile file: Int) -> Int? {
        rows.firstIndex(of: .file(file))
    }

    /// The hunk a row belongs to: its header or one of its lines.
    public func hunk(ofRow index: Int) -> (file: Int, hunk: Int)? {
        guard rows.indices.contains(index) else { return nil }
        switch rows[index] {
        case .hunk(let file, let hunk), .line(let file, let hunk, _): return (file, hunk)
        default: return nil
        }
    }

    /// Where a hunk's rows end (row coordinates): its last line's bottom.
    public func bottom(ofHunk file: Int, _ hunk: Int) -> CGFloat? {
        guard var index = index(ofHunk: file, hunk) else { return nil }
        while index + 1 < rows.count, case .line(file, hunk, _) = rows[index + 1] { index += 1 }
        return tops[index] + height(ofRow: index)
    }

    /// The file whose section is under the top of a viewport scrolled by `scroll` while its
    /// header is scrolled away (what the tile pins to the top), and how far the next file's
    /// header pushes it up (≤ 0).
    public func stickyFile(scroll: CGFloat) -> (file: Int, offset: CGFloat)? {
        guard scroll > 0, let top = index(atY: scroll), let file = rows[top].file, let header = index(ofFile: file), tops[header] < scroll else { return nil }
        if case .listed = rows[top] { return nil }
        let next = rows[(top + 1)...].firstIndex { if case .file = $0 { return true } else { return false } }
        let offset = next.map { min(0, tops[$0] - scroll - ChangesMetrics.fileHeight) } ?? 0
        return (file, offset)
    }
}

extension ChangeSet {
    /// Every hunk in reading order, for next/previous (j/k).
    public var hunkOrder: [(file: Int, hunk: Int)] {
        files.indices.flatMap { file in files[file].hunks.indices.map { (file, $0) } }
    }

    /// Where a hunk's line is in the board's files: a removed line on the old side of the file
    /// as the base named it, anything else on the new side. What a click opens and a Hyper-click
    /// mentions.
    public func location(file: Int, hunk: Int, line: Int) -> (path: String, line: Int, side: DiffSide)? {
        guard files.indices.contains(file), files[file].hunks.indices.contains(hunk), files[file].hunks[hunk].lines.indices.contains(line) else { return nil }
        let changed = files[file]
        let row = changed.hunks[hunk].lines[line]
        if row.kind == .removed, let old = row.old { return (changed.oldBoardPath ?? changed.boardPath, old, .old) }
        guard let new = row.new else { return nil }
        return (changed.boardPath, new, .new)
    }

    /// What a mention of a hunk's lines says about them beyond file and line: the kind of line
    /// (`added`, `removed`, `context`; lines of several kinds: `changed`) and the hunk's index
    /// state, e.g. `added line · unstaged hunk`; a whole hunk: `whole hunk +3 −1 · partly staged`.
    public func mentionDetail(file: Int, hunk: Int, lines: Range<Int>?) -> String? {
        guard files.indices.contains(file), files[file].hunks.indices.contains(hunk) else { return nil }
        let target = files[file].hunks[hunk]
        let state: String
        switch target.status {
        case .unstaged: state = "unstaged"
        case .partial: state = "partly staged"
        case .staged: state = "staged"
        case .committed: state = "committed"
        }
        guard let lines else { return "whole hunk +\(target.added) −\(target.removed) · \(state)" }
        let kinds = Set(target.lines[lines.clamped(to: target.lines.indices)].map(\.kind))
        let kind: String
        switch kinds.count == 1 ? kinds.first : nil {
        case .added?: kind = "added"
        case .removed?: kind = "removed"
        case .context?: kind = "context"
        case nil: kind = "changed"
        }
        return "\(kind) \(lines.count == 1 ? "line" : "lines") · \(state) hunk"
    }

    /// The working-tree line a hunk opens at: its first added or changed line, else (a pure
    /// deletion) the line after the removed ones, clamped to the file; a deleted file's first
    /// removed line in its base version.
    public func openLine(file: Int, hunk: Int) -> Int? {
        guard files.indices.contains(file), files[file].hunks.indices.contains(hunk) else { return nil }
        let changed = files[file], target = changed.hunks[hunk]
        if changed.status == .deleted { return target.mappings.first?.original.lowerBound ?? 1 }
        return min(max(1, target.modified.lowerBound), max(1, changed.new.lineCount))
    }
}
