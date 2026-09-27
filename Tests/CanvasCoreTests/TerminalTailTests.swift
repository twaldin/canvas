import Foundation
import Testing
import CanvasCore

struct TerminalTailTests {
    func tail(_ text: String, limit: Int, chunk: Int? = nil) -> (text: String, lines: Int) {
        var tail = TerminalTail(limit: limit)
        let bytes = Data(text.utf8)
        var start = 0
        let size = chunk ?? max(1, bytes.count)
        while start < bytes.count {
            tail.append(bytes.subdata(in: start..<min(bytes.count, start + size)))
            start += size
        }
        return tail.finish()
    }

    @Test func keepsTheLastLinesOfALongScrollback() {
        let text = (1...200_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let result = tail(text, limit: 3)
        #expect(result.text == "line 199998\nline 199999\nline 200000")
        #expect(result.lines == 3)
    }

    @Test func dropsTrailingBlankRowsEvenWhenThereAreMoreThanTheLimit() {
        let text = "a\nb\ncontent\n" + String(repeating: "      \n", count: 50)
        #expect(tail(text, limit: 2).text == "b\ncontent")
    }

    @Test func keepsBlankLinesBetweenContentAndTrimsRowPadding() {
        let text = "one   \r\n\n   \ntwo\t \n"
        let result = tail(text, limit: 10)
        #expect(result.text == "one\n\n\ntwo")
        #expect(result.lines == 4)
    }

    @Test func chunkBoundariesInsideLinesAndCharactersDoNotChangeTheResult() {
        let text = "héllo wörld ✓\nsecond — line\nthird 🙂 no newline"
        let whole = tail(text, limit: 2)
        #expect(whole.text == "second — line\nthird 🙂 no newline")
        for size in [1, 2, 3, 5, 7] {
            #expect(tail(text, limit: 2, chunk: size).text == whole.text)
        }
    }

    @Test func inlineImagePlaceholdersReadAsOneImageLine() {
        // What omp prints for an image: rows of U+10EEEE cells, each with row/column diacritics.
        let diacritics: [Character] = ["\u{0305}", "\u{030D}", "\u{030E}", "\u{0310}"]
        let rows = (0..<4).map { row in "  " + diacritics.map { column in "\u{10EEEE}\(diacritics[row])\(column)" }.joined() }
        let text = (["read shot.png"] + rows + ["  done \u{10EEEE}\u{0305}\u{0305} inline", "tail"]).joined(separator: "\n")
        let result = tail(text, limit: 10)
        #expect(result.text == "read shot.png\n  [image]\n  done [image] inline\ntail")
        #expect(!result.text.unicodeScalars.contains("\u{10EEEE}"))
        // Split mid-character, the same.
        #expect(tail(text, limit: 10, chunk: 3).text == result.text)
    }

    @Test func emptyOrAllBlankTextHasNoLines() {
        #expect(tail("", limit: 5).lines == 0)
        #expect(tail("   \n\n  \n", limit: 5) == ("", 0))
    }
}
