import CoreGraphics
import Foundation
import Testing
@testable import CanvasCore

/// Soft-wrapped code rows: where lines break, how visual rows map to lines and peeks, what a
/// continuation row's positions mean, and what a selection copies.
struct CodeWrapTests {
    @Test func longLinesBreakAtTheColumnWithAnIndentedContinuation() {
        #expect(CodeMetrics.wrap("short".utf16, columns: 10) == ([], 0), "a line that fits doesn't break")
        #expect(CodeMetrics.wrap("0123456789".utf16, columns: 10).breaks == [], "exactly the width fits")
        let plain = CodeMetrics.wrap("abcdefghij".utf16, columns: 4)
        #expect(plain.breaks == [4, 6, 8] && plain.indent == 2, "continuations start 2 columns in, so they hold 2 of 4")

        // Continuations keep the line's own indentation (+2), capped at half the row.
        let indented = CodeMetrics.wrap("    let x = 1234567890".utf16, columns: 16)
        #expect(indented.indent == 6 && indented.breaks == [16], "16 columns, then `567890` at indent 6")
        #expect(CodeMetrics.wrap((String(repeating: " ", count: 30) + "x").utf16, columns: 16).indent == 8)
    }

    @Test func tabsAndWideCharactersCountTheColumnsTheyDraw() {
        // A leading tab is 4 columns: the first row holds it and 6 a's; the rest wrap at indent 6.
        let tabbed = "\t" + String(repeating: "a", count: 12)
        #expect(CodeMetrics.columns(tabbed) == 16)
        let wrap = CodeMetrics.wrap(tabbed.utf16, columns: 10)
        #expect(wrap.indent == 5 && wrap.breaks == [7, 12], "indent 4 + 2 capped at half of 10; 5 a's, then the last")

        // A tab expands against the unwrapped line: after 6 columns it is 2 wide, so it moves to row 2.
        let late = CodeMetrics.wrap("abcdef\tgh".utf16, columns: 7)
        #expect(late.breaks == [6])

        let han = "漢字漢字漢字"
        #expect(CodeMetrics.columns(han) == 12, "wide characters take 2 columns")
        #expect(CodeMetrics.wrap(han.utf16, columns: 5).breaks == [2, 3, 4, 5])

        // An emoji is one surrogate pair, 2 columns, never split across rows.
        let emoji = "a😀😀"
        #expect(CodeMetrics.columns(emoji) == 5)
        #expect(CodeMetrics.wrap(emoji.utf16, columns: 2).breaks == [1, 3])
    }

    /// Line 2 is 18 columns in the working tree and 25 in the base; at 10 columns the new line
    /// takes 2 rows and the peeked base line 3.
    static let old = SideText("one\n" + String(repeating: "o", count: 25) + "\nthree")
    static let new = SideText("one\n" + String(repeating: "n", count: 18) + "\nthree\n")
    static let signs = [GitSign(kind: .modified, lines: 2..<3, old: 2..<3)]

    @Test func visualRowsMapToTheirLogicalLinesIncludingWrappedPeeks() {
        let rows = CodeRows(text: WrapText(Self.new), old: WrapText(Self.old), signs: Self.signs, peeked: [0], columns: 10)
        #expect(rows.entryCount == 4 && rows.count == 7)
        #expect((0..<rows.count).compactMap(rows.row) == [
            .line(1),
            .peek(old: 2, sign: 0), .peek(old: 2, sign: 0), .peek(old: 2, sign: 0),
            .line(2), .line(2),
            .line(3),
        ])
        #expect(rows.segment(2) == CodeRows.Segment(entry: 1, row: .peek(old: 2, sign: 0), part: 1, start: 10, end: 18, indent: 2))
        #expect(rows.segment(3) == CodeRows.Segment(entry: 1, row: .peek(old: 2, sign: 0), part: 2, start: 18, end: nil, indent: 2))
        #expect(rows.segment(5)?.start == 10 && rows.segment(5)?.end == nil && rows.segment(4)?.end == 10)
        #expect(rows.segment(7) == nil && rows.row(-1) == nil)

        #expect(rows.index(ofLine: 2) == 4 && rows.rows(ofLine: 2) == 4..<6, "a line's first row, and all of its rows")
        #expect(rows.index(ofLine: 3) == 6)
        #expect(rows.index(ofPeek: 0, old: 2) == 1 && rows.rows(ofEntry: 1) == 1..<4)
        #expect(rows.edgeRow(ofLine: 4) == 7, "the edge below the last line is below its last row")

        let closed = CodeRows(text: WrapText(Self.new), old: WrapText(Self.old), signs: Self.signs, columns: 10)
        #expect((0..<closed.count).compactMap(closed.row) == [.line(1), .line(2), .line(2), .line(3)])

        let unwrapped = CodeRows(text: WrapText(Self.new), old: WrapText(Self.old), signs: Self.signs, peeked: [0], columns: nil)
        #expect(unwrapped == CodeRows(lineCount: 3, signs: Self.signs, peeked: [0]))
        #expect(unwrapped.count == 4 && unwrapped.index(ofLine: 2) == 2)
    }

    @Test func aTileSizedForNColumnsWrapsLinesPastN() {
        let document = CodeDocument(path: "a.txt", diff: FileDiff(state: .modified, base: "abc", baseLabel: "HEAD", old: Self.old, new: Self.new,
                                                                  hunks: [DiffHunk(mappings: [LineRangeMapping(original: 2..<3, modified: 2..<3)])]))
        func width(_ columns: Int) -> CGFloat {
            (CodeMetrics.gutterWidth(lineCount: document.gutterLineCount) + CGFloat(columns) * CodeMetrics.charAdvance + CodeMetrics.trailingPadding).rounded(.up)
        }
        #expect(document.rows(peeked: [0], width: width(25)).count == 4, "25 columns show the base line whole")
        #expect(document.rows(peeked: [0], width: width(24)).count == 5)
        #expect(document.rows(peeked: [0], width: width(10)).count == 7)
        #expect(document.rows(peeked: [0], width: nil).count == 4)
    }

    @Test func continuationRowsMapPositionsIntoTheirLine() {
        let document = CodeDocument(path: "a.txt", diff: FileDiff(state: .modified, base: "abc", baseLabel: "HEAD", old: Self.old, new: Self.new,
                                                                  hunks: [DiffHunk(mappings: [LineRangeMapping(original: 2..<3, modified: 2..<3)])]))
        let rows = CodeRows(text: document.wrapText, old: document.oldWrapText, signs: document.signs, peeked: [0], columns: 10)
        let continuation = document.rowText(try! #require(rows.segment(5)))
        #expect(continuation.display == "nnnnnnnn")
        #expect(continuation.offset(ofDisplay: 3) == 13, "the 4th character of the second row is column 13 of line 2")
        #expect(continuation.offset(ofDisplay: 99) == 18 && continuation.display(ofOffset: 12) == 2)

        // Tabs on a continuation row expand against the unwrapped line (the tab starts at column 6).
        let tabbed = WrapText(SideText("abcdef\tgh"))
        let tabRows = CodeRows(text: tabbed, columns: 7)
        let tabDocument = CodeDocument(path: "t.txt", diff: FileDiff(state: .noBase, base: nil, baseLabel: nil, old: SideText(""), new: tabbed.text, hunks: []))
        let second = tabDocument.rowText(try! #require(tabRows.segment(1)))
        #expect(second.display == "  gh")
        #expect(second.offset(ofDisplay: 1) == 6 && second.offset(ofDisplay: 2) == 7 && second.display(ofOffset: 8) == 3)
    }

    @Test func aSelectionCopiesLogicalLinesNotVisualRows() {
        let document = CodeDocument(path: "a.txt", diff: FileDiff(state: .modified, base: "abc", baseLabel: "HEAD", old: Self.old, new: Self.new,
                                                                  hunks: [DiffHunk(mappings: [LineRangeMapping(original: 2..<3, modified: 2..<3)])]))
        let rows = CodeRows(text: document.wrapText, old: document.oldWrapText, signs: document.signs, peeked: [0], columns: 10)
        typealias P = CodeRows.Position
        // From inside the wrapped base line (its third row) into the wrapped new line's second row.
        #expect(document.text(rows: rows, from: P(entry: 1, offset: 20), to: P(entry: 2, offset: 12))
                == "ooooo\n" + String(repeating: "n", count: 12), "no breaks where rows wrap")
        #expect(document.text(rows: rows, from: P(entry: 0, offset: 1), to: P(entry: 3, offset: 5))
                == "ne\n" + String(repeating: "o", count: 25) + "\n" + String(repeating: "n", count: 18) + "\nthree")
        #expect(document.text(rows: rows, from: P(entry: 2, offset: 4), to: P(entry: 2, offset: 4)) == "")
    }
}
