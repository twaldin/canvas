import Foundation
import Testing
import CanvasCore

/// `zmx history --vt` output → styled lines for terminal renders.
struct TerminalStyledTailTests {
    func parse(_ text: String, limit: Int = 100, chunk: Int? = nil) -> (lines: [TerminalLine], cursorRow: Int?) {
        var tail = TerminalStyledTail(limit: limit)
        let bytes = Data(text.utf8)
        let size = chunk ?? max(1, bytes.count)
        var start = 0
        while start < bytes.count {
            tail.append(bytes.subdata(in: start..<min(bytes.count, start + size)))
            start += size
        }
        let lines = tail.finish()
        return (lines, tail.cursorRow)
    }

    @Test func colorsAndAttributesBecomeRuns() {
        let line = parse("\u{1B}[38;2;162;236;185m\u{1B}[48;2;15;16;25mok\u{1B}[0m plain \u{1B}[1;38;5;238mbold\u{1B}[22;39m\r\n").lines[0]
        #expect(line.text == "ok plain bold")
        var green = TerminalStyle()
        green.foreground = .rgb(162, 236, 185)
        green.background = .rgb(15, 16, 25)
        var bold = TerminalStyle()
        bold.bold = true
        bold.foreground = .indexed(238)
        #expect(line.runs == [TerminalRun(text: "ok", style: green), TerminalRun(text: " plain ", style: TerminalStyle()), TerminalRun(text: "bold", style: bold)])
    }

    @Test func styleCarriesAcrossLinesAndChunks() {
        let result = parse("\u{1B}[31mred\nstill red\u{1B}[m\nplain\n", chunk: 3)
        #expect(result.lines.map { $0.runs.map(\.style.foreground) } == [[.indexed(1)], [.indexed(1)], [.standard]])
    }

    @Test func brightColonAndPrivateSequences() {
        let line = parse("\u{1B}[92mA\u{1B}[38:2::1:2:3mB\u{1B}[?25l\u{1B}[=5;1uC\u{1B}]0;title\u{07}D\u{1B}]8;;x\u{1B}\\E\n").lines[0]
        #expect(line.text == "ABCDE", "cursor modes, keyboard modes and OSC titles/links are dropped")
        #expect(line.runs.map(\.style.foreground) == [.indexed(10), .rgb(1, 2, 3)])
    }

    @Test func keepsTheLastLinesAndTheFinalCursorRow() {
        let text = (1...5000).map { "\u{1B}[3\($0 % 8)mline \($0)" }.joined(separator: "\r\n") + "\u{1B}[21;4H\u{1B}[0m"
        let result = parse(text, limit: 3, chunk: 4096)
        #expect(result.lines.map(\.text) == ["line 4998", "line 4999", "line 5000"])
        #expect(result.lines.last?.runs.first?.style.foreground == .indexed(0))
        #expect(result.cursorRow == 21)
    }

    @Test func tabsExpandToTheNextStop() {
        #expect(parse("ab\tc\n").lines[0].text == "ab      c")
    }

    @Test func cellWidths() {
        #expect(TerminalStyledTail.cellWidth("a") == 1)
        #expect(TerminalStyledTail.cellWidth("\u{E0B0}") == 1, "powerline separators are one cell")
        #expect(TerminalStyledTail.cellWidth("\u{F0D57}") == 1, "Nerd Font material icons are one cell")
        #expect(TerminalStyledTail.cellWidth("漢") == 2)
        #expect(TerminalStyledTail.cellWidth("🤖") == 2)
    }

    @Test func paletteCubeAndGrays() {
        #expect(TerminalColor.xterm(1) == nil, "0–15 come from the theme")
        #expect(TerminalColor.xterm(16).map { [$0.0, $0.1, $0.2] } == [0, 0, 0])
        #expect(TerminalColor.xterm(231).map { [$0.0, $0.1, $0.2] } == [255, 255, 255])
        #expect(TerminalColor.xterm(238).map { [$0.0, $0.1, $0.2] } == [68, 68, 68])
    }
}
