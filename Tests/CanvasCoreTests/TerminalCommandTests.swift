import Foundation
import Testing
import CanvasCore

struct TerminalCommandTests {
    func tail(_ text: String, columns: Int?) -> String {
        var tail = TerminalTail(limit: 50, columns: columns)
        tail.append(Data(text.utf8))
        return tail.finish().text
    }

    @Test func softWrappedRowsReadAsOneLineButBordersAndShortRowsStayRows() {
        // 10 columns: a Go assertion wrapped mid-word joins; a full-width box line, a row
        // ending in a blank at the edge, and a row followed by a TUI border stay apart.
        #expect(tail("want \"ab w\nant\"\nnext\n", columns: 10) == "want \"ab want\"\nnext")
        #expect(tail("0123456789abcdefghijKL\n", columns: 10) == "0123456789abcdefghijKL", "a line wrapped twice")
        #expect(tail("──────────\ntext\n", columns: 10) == "──────────\ntext")
        #expect(tail("short row\nnext\n", columns: 10) == "short row\nnext")
        #expect(tail("0123456789\n│ frame │\n", columns: 10) == "0123456789\n│ frame │")
        #expect(tail("0123456789\n\nafter\n", columns: 10) == "0123456789\n\nafter", "a blank row ends the line")
        #expect(tail("want \"a b w\nant\"\n", columns: nil) == "want \"a b w\nant\"", "unknown width: rows as they are")
    }

    @Test func longTerminalTextKeepsItsHeadAndTailAndSaysHowMuchWasLeftOut() {
        let lines = (1...50).map { "line \($0)" }
        #expect(TerminalExcerpt.trim(lines, head: 2, tail: 3) == ["line 1", "line 2", "… 45 lines omitted …", "line 48", "line 49", "line 50"])
        #expect(TerminalExcerpt.trim(Array(lines.prefix(6)), head: 2, tail: 3) == Array(lines.prefix(6)), "one more line than fits beats a marker")
        #expect(TerminalExcerpt.lines("\n\n  a  \nb\n\n") == ["  a", "b"])
    }

    @Test func rowsAroundAClickMarkTheClickedRowAndDropBlankEdges() {
        let rows = ["", "--- FAIL: TestWrap", "    zz_test.go:16: got x", "FAIL", "", ""]
        #expect(TerminalExcerpt.around(rows, index: 2, before: 8, after: 3) == ["  --- FAIL: TestWrap", ">     zz_test.go:16: got x", "  FAIL"])
    }

    @Test func theCommandIsTheFirstTitleAfterThePromptNotThePromptsOwnTitles() {
        var tracker = TerminalCommandTracker()
        let t0 = Date()
        tracker.prompt(at: t0)
        tracker.title("~/src/app", at: t0.addingTimeInterval(0.01), promptTitle: "~/src/app")
        tracker.title("zsh in app", at: t0.addingTimeInterval(0.05), promptTitle: "~/src/app")
        tracker.title("go test ./...", at: t0.addingTimeInterval(2), promptTitle: "~/src/app")
        tracker.title("vim main.go", at: t0.addingTimeInterval(3), promptTitle: "~/src/app")
        let first = tracker.finished(exit: 1, durationNanos: 42_000_000_000, at: t0.addingTimeInterval(44))
        #expect(first == TerminalCommand(command: "go test ./...", exit: 1, durationMs: 42_000))
        // The framework's prompt title again, well after the prompt (a redraw): still not a command.
        tracker.title("zsh in app", at: t0.addingTimeInterval(44.01), promptTitle: "~/src/app")
        tracker.title("zsh in app", at: t0.addingTimeInterval(50), promptTitle: "~/src/app")
        tracker.running(program: "make")
        #expect(tracker.finished(exit: 0, durationNanos: 1_000_000, at: t0.addingTimeInterval(60)).command == "make", "no title: the program seen running")
        #expect(TerminalCommandTracker.promptTitle(cwd: "/Users/me/src/app", home: "/Users/me") == "~/src/app")
        #expect(TerminalCommandTracker.promptTitle(cwd: "/tmp/x", home: "/Users/me") == "/tmp/x")
    }

    @Test func statusShowsOnlyFailuresAndLongRunsAndTheMarkerSaysWhatRan() {
        #expect(TerminalCommand(command: "ls", exit: 0, durationMs: 40).status == nil)
        #expect(TerminalCommand(command: "false", exit: 1, durationMs: 40).status == "exit 1")
        #expect(TerminalCommand(command: "go test", exit: 1, durationMs: 42_300).status == "exit 1 · 42 s")
        #expect(TerminalCommand(command: "make", exit: 0, durationMs: 182_000).status == "3 min 2 s")
        #expect(TerminalCommand(command: "go test ./...", exit: 1, durationMs: 42_000).noticeMessage == "go test ./... exited 1 · 42 s")
        #expect(TerminalCommand(exit: 0, durationMs: 3_600_000 + 300_000).noticeMessage == "Command finished · 1 h 5 min")
    }

    @Test func aBlockGetsTheLastCommandsExitOnlyWhenItIsThatCommandsBlock() {
        let last = TerminalCommand(command: "go test ./...", exit: 1, durationMs: 900)
        // Output ending two rows above the cursor (a two-line prompt), under its own command line.
        #expect(TerminalBlocks.command(promptRow: "❯ go test ./...", outputEnd: 18, cursorRow: 20, atPrompt: true, last: last) == last)
        // An older block: just its command line as shown, without the prompt's symbol.
        #expect(TerminalBlocks.command(promptRow: "❯ go vet", outputEnd: 8, cursorRow: 20, atPrompt: true, last: last) == TerminalCommand(command: "go vet"))
        // The same place, but its prompt row ran something else (the last command printed nothing).
        #expect(TerminalBlocks.command(promptRow: "❯ go vet", outputEnd: 18, cursorRow: 20, atPrompt: true, last: last) == TerminalCommand(command: "go vet"))
        // Still running: the shell's last command is an earlier one.
        #expect(TerminalBlocks.command(promptRow: "❯ go test ./...", outputEnd: 18, cursorRow: 19, atPrompt: false, last: last) == TerminalCommand(command: "go test ./..."))
        #expect(TerminalBlocks.commandLine("$ ls -la") == "ls -la")
        #expect(TerminalBlocks.commandLine("% ./run.sh") == "./run.sh")
        #expect(TerminalBlocks.commandLine("./run.sh --fast") == "./run.sh --fast")
        #expect(TerminalBlocks.commandLine("~/dev ❯ make") == "~/dev ❯ make")
        #expect(TerminalBlocks.commandLine("git status") == "git status")
        #expect(TerminalBlocks.rows(of: "12345\n\n1234567890123", columns: 10) == 4)
    }

    @Test func aBlockFromBeforeAReattachStartsAfterItsCommandsLine() {
        let output = "❯ make\nold output\n❯ go test ./...\n--- FAIL: TestX\nFAIL"
        #expect(TerminalBlocks.output(output, after: "go test ./...") == "--- FAIL: TestX\nFAIL")
        #expect(TerminalBlocks.output("--- FAIL: TestX", after: "go test ./...") == "--- FAIL: TestX")
    }

    @Test func pytestNodeIdsFindTheirDefinition() {
        let source = """
        import pytest

        def test_help():
            pass

        class TestGroup:
            def test_other(self):
                pass

            @pytest.mark.parametrize("x", [1])
            def test_help(self, x):
                pass

        class TestLater:
            def test_help(self):
                pass
        """
        #expect(PytestNode.line(of: ["test_help"], in: source) == 3)
        #expect(PytestNode.line(of: ["TestGroup", "test_help"], in: source) == 11)
        #expect(PytestNode.line(of: ["TestLater", "test_help"], in: source) == 15)
        #expect(PytestNode.line(of: ["TestGroup", "test_missing"], in: source) == nil)
        let refs = TerminalReferences.find(in: "FAILED tests/test_cli.py::TestGroup::test_help[1-a] - AssertionError, see tests/test_cli.py:12")
        #expect(refs.map(\.path) == ["tests/test_cli.py", "tests/test_cli.py"])
        #expect(refs.map(\.test) == [["TestGroup", "test_help"], nil])
    }

    @Test func aRangeWrappedInsideATableCellJoins() {
        let rows = ["│ 5. Anonymous requests │ Low-Med │ server/routes/trade-ups.ts:1383-13 │",
                    "│                      │         │ 92                                 │"]
        let hit = TerminalReferences.hit(row: 0, column: 40, columns: 80, read: { rows.indices.contains($0) ? rows[$0] : nil },
                                         resolve: { $0 == "server/routes/trade-ups.ts" ? $0 : nil })
        #expect(hit?.lines == LineRange(start: 1383, end: 1392))
        // A next table row with more in it than digits is its own row.
        let other = [rows[0], "│ 6. Next finding │ Low │ 92 more │"]
        let alone = TerminalReferences.hit(row: 0, column: 40, columns: 80, read: { other.indices.contains($0) ? other[$0] : nil },
                                           resolve: { $0 == "server/routes/trade-ups.ts" ? $0 : nil })
        #expect(alone?.lines == LineRange(start: 1383, end: 1383))
    }

    @Test func tilesLoadGhosttysIntegrationUnlessTheUserTurnedItOff() {
        let resources = URL(fileURLWithPath: "/app/Ghostty")
        let present: (String) -> Bool = { $0 == "/app/Ghostty/shell-integration" }
        #expect(TerminalShellIntegration.directory(setting: nil, resources: resources, isDirectory: present) == "/app/Ghostty/shell-integration")
        #expect(TerminalShellIntegration.directory(setting: "detect", resources: resources, isDirectory: present) == "/app/Ghostty/shell-integration")
        #expect(TerminalShellIntegration.directory(setting: " none ", resources: resources, isDirectory: present) == nil)
        #expect(TerminalShellIntegration.directory(setting: "zsh", resources: resources, isDirectory: { _ in false }) == nil)
    }
}

@MainActor
struct TerminalMentionTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-tests-\(UUID().uuidString)")

    @Test func terminalMentionsCarryTheirTextAndPointAtAgentRead() async throws {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = Board(id: "brd_test", root: root)
        let shell = board.create(type: .terminal, props: .object([:])).id
        board.terminalLabel = { $0 == shell ? "go · ~/src/app" : nil }
        board.terminalScreen = { _ in "❯ ls\nREADME.md\n" }
        let output = (1...60).map { "ok \($0)" }.joined(separator: "\n")
        try board.stage(.terminal(object: shell, text: output, part: .command, command: TerminalCommand(command: "go test ./...", exit: 1, durationMs: 42_000)))
        try board.stage(.object(shell))
        let context = await board.drain().context
        #expect(context.contains("[1] command `go test ./...` · exit 1 · 42 s · output of terminal tile \(shell) \"go · ~/src/app\""))
        #expect(context.contains("    ok 10\n    … 20 lines omitted …\n    ok 31"))
        #expect(context.contains("[2] terminal \(shell) \"go · ~/src/app\""))
        #expect(context.contains("    README.md"))
        #expect(context.contains("canvas agent.read --target <id>"))
        #expect(!context.contains("canvas get <id> --as graph"), "only terminals mentioned")
    }
}
