import Foundation

/// Geometry of a changes tile: a header strip, then rows (a file header, its hunks' headers,
/// their unified-diff lines). Lines use the code tile's font and row height (`CodeMetrics`);
/// long lines are clipped, not wrapped. `object.measure` and `size: "fit"` use the same numbers.
public enum ChangesMetrics {
    public static let headerHeight: CGFloat = 26
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
    /// Width of each drawn button in a file or hunk header ("Stage", "Revert").
    public static let buttonWidth: CGFloat = 54
    public static let buttonGap: CGFloat = 6
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

    /// The frame (title bar included) that shows every row of `set` without scrolling, as wide
    /// as its longest line up to `maxWidth` (at least `minWidth`), at most `maxFitHeight` tall.
    public static func fit(_ set: ChangeSet, maxWidth: CGFloat?) -> CGSize {
        let rows = ChangeRows(set, collapsed: [])
        var longest = 0
        for file in set.files {
            for hunk in file.hunks {
                for line in hunk.lines {
                    let text = line.kind == .removed ? file.old : file.new
                    guard let number = line.kind == .removed ? line.old : line.new, number <= text.lineCount else { continue }
                    longest = max(longest, CodeMetrics.columns(text.line(number)))
                }
            }
            longest = max(longest, file.boardPath.count + 16)
        }
        let natural = gutterWidth(digits: digits(set)) + CGFloat(longest) * CodeMetrics.charAdvance + trailingPadding
        let width = min(max(natural.rounded(.up), minWidth), max(minWidth, (maxWidth ?? defaultFitWidth).rounded(.down)))
        let height = CodeMetrics.titleHeight + headerHeight + rows.height + bottomPadding
        return CGSize(width: width, height: min(height.rounded(.up), maxFitHeight))
    }
}

/// The rows a changes tile draws, top to bottom, with each row's top (below the header strip).
public struct ChangeRows: Equatable, Sendable {
    public enum Row: Equatable, Sendable {
        case file(Int)
        case hunk(file: Int, hunk: Int)
        case line(file: Int, hunk: Int, line: Int)
        /// Why a file has no hunks (binary, too large…).
        case notice(file: Int)
        /// Nothing to list, and why.
        case message(String)
        /// Files past `ChangeSet.maxFiles`.
        case omitted(Int)
    }

    public let rows: [Row]
    public let tops: [CGFloat]
    public let height: CGFloat

    /// `collapsed`: board paths of files shown as their header only.
    public init(_ set: ChangeSet, collapsed: Set<String>) {
        var rows: [Row] = []
        if let notice = set.notice {
            rows.append(.message(notice))
        } else if set.files.isEmpty {
            rows.append(.message("No changes against \(set.baseLabel.isEmpty ? "the base" : set.baseLabel)"))
        }
        for (index, file) in set.files.enumerated() {
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
        tops.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for row in rows {
            tops.append(y)
            y += Self.height(of: row)
        }
        self.rows = rows
        self.tops = tops
        height = y
    }

    public static func height(of row: Row) -> CGFloat {
        switch row {
        case .file: ChangesMetrics.fileHeight
        case .hunk: ChangesMetrics.hunkHeight
        case .line: ChangesMetrics.lineHeight
        case .notice, .omitted: ChangesMetrics.noticeHeight
        case .message: ChangesMetrics.messageHeight
        }
    }

    public func height(ofRow index: Int) -> CGFloat { Self.height(of: rows[index]) }

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
