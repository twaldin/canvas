import Foundation

/// The text a code tile shows: one row per display line, each a fixed-width gutter (old and new
/// line numbers, change marker) followed by the line. In diff mode the whole new file is shown
/// with the real deleted rows interleaved and a header row above each hunk; in source mode, the
/// file alone. Every row maps back to a line on its side.
public struct DiffDisplay: Sendable {
    public enum Mode: String, Sendable {
        case diff, source
    }

    public enum RowKind: Sendable, Equatable {
        case context, deleted, added, header
    }

    public struct Row: Sendable, Equatable {
        public var kind: RowKind
        public var oldLine: Int?
        public var newLine: Int?
        /// The hunk a change or header row belongs to.
        public var hunk: Int?
        /// UTF-16 offset of the row's first gutter character in `text`.
        public var offset: Int

        /// The side and line this row shows: deleted rows show the old side, others the new.
        public var sourceLine: (side: DiffSide, line: Int)? {
            switch kind {
            case .deleted: oldLine.map { (.old, $0) }
            case .context, .added: newLine.map { (.new, $0) }
            case .header: nil
            }
        }
    }

    public let mode: Mode
    public let text: String
    public let rows: [Row]
    /// UTF-16 length of the gutter that starts every row.
    public let gutterWidth: Int
    public let utf16Count: Int

    /// `hunkTitles` (per hunk, e.g. the enclosing symbol) follow each header like git's funcname.
    public init(_ diff: FileDiff, mode: Mode, hunkTitles: [String?] = []) {
        self.mode = mode
        var rows: [Row] = []
        switch (mode, diff.state) {
        case (.diff, .modified), (.diff, .added), (_, .deleted):
            rows = Self.diffRows(diff)
        default:
            rows = (0..<diff.new.lineCount).map { Row(kind: .context, oldLine: nil, newLine: $0 + 1, hunk: nil, offset: 0) }
        }
        let showsOld = diff.state == .deleted || (mode == .diff && diff.state == .modified)
        let numberWidth = max(3, String(max(diff.old.lineCount, diff.new.lineCount)).count)
        let blank = String(repeating: " ", count: numberWidth)
        func number(_ value: Int?) -> String {
            guard let value else { return blank }
            let digits = String(value)
            return String(repeating: " ", count: numberWidth - digits.count) + digits
        }
        let gutterWidth = (showsOld ? numberWidth + 1 : 0) + numberWidth + 3
        let out = NSMutableString()
        let oldSource = diff.old.text as NSString
        let newSource = diff.new.text as NSString
        for index in rows.indices {
            rows[index].offset = out.length
            let row = rows[index]
            let marker: String
            switch row.kind {
            case .deleted: marker = "-"
            case .added: marker = "+"
            case .context, .header: marker = " "
            }
            if showsOld {
                out.append(number(row.oldLine))
                out.append(" ")
            }
            out.append(number(row.newLine))
            out.append(" ")
            out.append(marker)
            out.append(" ")
            switch row.kind {
            case .header:
                out.append(diff.hunks[row.hunk!].header)
                if let title = hunkTitles.indices.contains(row.hunk!) ? hunkTitles[row.hunk!] : nil {
                    out.append("  ")
                    out.append(title)
                }
            case .deleted:
                out.append(oldSource.substring(with: diff.old.range(ofLine: row.oldLine!)))
            case .context, .added:
                out.append(newSource.substring(with: diff.new.range(ofLine: row.newLine!)))
            }
            out.append("\n")
        }
        self.rows = rows
        self.gutterWidth = gutterWidth
        text = out as String
        utf16Count = out.length
    }

    private static func diffRows(_ diff: FileDiff) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(diff.new.lineCount + diff.removedCount + diff.hunks.count)
        var oldLine = 1
        var newLine = 1
        func context(until end: Int) {
            while newLine < end, newLine <= diff.new.lineCount {
                rows.append(Row(kind: .context, oldLine: oldLine, newLine: newLine, hunk: nil, offset: 0))
                oldLine += 1
                newLine += 1
            }
        }
        for (index, hunk) in diff.hunks.enumerated() {
            for (position, mapping) in hunk.mappings.enumerated() {
                context(until: mapping.modified.lowerBound)
                if position == 0 { rows.append(Row(kind: .header, oldLine: nil, newLine: nil, hunk: index, offset: 0)) }
                for line in mapping.original where line <= diff.old.lineCount {
                    rows.append(Row(kind: .deleted, oldLine: line, newLine: nil, hunk: index, offset: 0))
                }
                for line in mapping.modified where line <= diff.new.lineCount {
                    rows.append(Row(kind: .added, oldLine: nil, newLine: line, hunk: index, offset: 0))
                }
                oldLine = mapping.original.upperBound
                newLine = mapping.modified.upperBound
            }
        }
        context(until: diff.new.lineCount + 1)
        return rows
    }

    // MARK: Lookup

    /// Row index containing a UTF-16 offset of `text`.
    public func row(atOffset offset: Int) -> Int? {
        guard !rows.isEmpty else { return nil }
        var low = 0
        var high = rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if rows[mid].offset <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// UTF-16 range of a row, without its line break.
    public func range(ofRow index: Int) -> NSRange {
        let end = index + 1 < rows.count ? rows[index + 1].offset - 1 : utf16Count - 1
        return NSRange(location: rows[index].offset, length: max(0, end - rows[index].offset))
    }

    /// Row showing a line on one side: deleted rows for the old side, context/added for the new.
    public func row(showing line: Int, side: DiffSide) -> Int? {
        switch side {
        case .new: rows.firstIndex { $0.kind != .deleted && $0.newLine == line }
        case .old: rows.firstIndex { $0.kind == .deleted && $0.oldLine == line } ?? rows.firstIndex { $0.kind == .context && $0.oldLine == line }
        }
    }

    /// Rows of a mention: the header and every row of the hunk when it matches the hunk's
    /// range, otherwise the rows showing those lines.
    public func rows(for lines: LineRange, side: DiffSide, hunks: [DiffHunk]) -> ClosedRange<Int>? {
        if let hunk = hunks.firstIndex(where: { $0.mentionLines.side == side && $0.mentionLines.lines == lines }),
           let first = rows.firstIndex(where: { $0.kind == .header && $0.hunk == hunk }) {
            let last = rows.lastIndex { $0.hunk == hunk } ?? first
            return first...last
        }
        let matching = rows.indices.filter { index in
            guard let shown = rows[index].sourceLine, shown.side == side else { return false }
            return (lines.start...lines.end).contains(shown.line)
        }
        guard let first = matching.first, let last = matching.last else { return nil }
        return first...last
    }

    public func headerRow(ofHunk hunk: Int) -> Int? {
        rows.firstIndex { $0.kind == .header && $0.hunk == hunk }
    }

    /// Syntax spans from each side moved onto the rows that show them: deleted rows take old-side
    /// spans, context and added rows take new-side spans.
    public func place(old: [SyntaxSpan], new: [SyntaxSpan], diff: FileDiff) -> [SyntaxSpan] {
        var oldRow: [Int: Int] = [:]
        var newRow: [Int: Int] = [:]
        for (index, row) in rows.enumerated() {
            switch row.kind {
            case .deleted: if let line = row.oldLine { oldRow[line] = index }
            case .context, .added: if let line = row.newLine { newRow[line] = index }
            case .header: break
            }
        }
        var placed: [SyntaxSpan] = []
        placed.reserveCapacity(old.count + new.count)
        func place(_ spans: [SyntaxSpan], _ side: SideText, _ rowFor: [Int: Int]) {
            for span in spans {
                var line = side.line(containing: span.range.location)
                let end = span.range.location + span.range.length
                while line <= side.lineCount, side.lineStarts[line - 1] < end {
                    defer { line += 1 }
                    guard let row = rowFor[line] else { continue }
                    let lineRange = side.range(ofLine: line)
                    let start = max(span.range.location, lineRange.location)
                    let stop = min(end, lineRange.location + lineRange.length)
                    guard stop > start else { continue }
                    let at = rows[row].offset + gutterWidth + (start - lineRange.location)
                    placed.append(SyntaxSpan(range: NSRange(location: at, length: stop - start), style: span.style))
                }
            }
        }
        if !oldRow.isEmpty { place(old, diff.old, oldRow) }
        place(new, diff.new, newRow)
        return placed
    }
}
