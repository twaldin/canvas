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

    @Test func aSeparatorPaddedToTheWidthNeverJoinsTheNextLine() {
        // pytest pads its section rules to the terminal's width exactly.
        #expect(tail("=== short summary ===\nFAILED tests/a.py::t\n", columns: 21) == "=== short summary ===\nFAILED tests/a.py::t")
        #expect(tail("!!!!!!!!!!\n1 failed\n", columns: 10) == "!!!!!!!!!!\n1 failed")
        #expect(tail("____ t ____\nrunner = x\n", columns: 11) == "____ t ____\nrunner = x")
        #expect(tail("----------\n==========\nnext\n", columns: 10) == "----------\n==========\nnext")
        #expect(tail("a == b ===\n=c\n", columns: 10) == "a == b ====c", "text ending in punctuation at the edge still wraps")
    }

    @Test func aBellNamesWhatRangIt() {
        let now = Date()
        let last = TerminalCommandLog.Entry(command: TerminalCommand(command: "make test", exit: 1, durationMs: 900), finishedAt: now.addingTimeInterval(-2))
        #expect(TerminalCommand.bellMessage(program: "pytest", shell: "zsh", last: last, at: now) == "pytest rang the bell", "the foreground program first")
        #expect(TerminalCommand.bellMessage(program: nil, shell: "zsh", last: last, at: now) == "Bell after `make test`")
        #expect(TerminalCommand.bellMessage(program: nil, shell: "zsh", last: last, at: now.addingTimeInterval(10)) == "zsh rang the bell", "a command long done isn't why")
        #expect(TerminalCommand.bellMessage(program: nil, shell: nil, last: nil, at: now) == "The shell rang the bell")
    }

    @Test func onlyOneLineOfPrintableTextIsTypedIntoAShell() {
        #expect(ShellTyping.action(#"clear; grep -n "a\b" x.py"#) == #"text:clear; grep -n "a\\b" x.py"#, "a backslash is escaped for Ghostty's parser")
        #expect(ShellTyping.action("écho ✓") == "text:écho ✓")
        #expect(ShellTyping.action("make\nmake install") == nil, "a newline would run the first line alone")
        #expect(ShellTyping.action("a\tb") == nil && ShellTyping.action("\u{1B}[A") == nil && ShellTyping.action("") == nil)
    }

    @Test func aFollowTileAimsAtAnEditsLargestHunkTheLastOfEquals() {
        let hunks = [LineRange(start: 28, end: 28), LineRange(start: 63, end: 63), LineRange(start: 106, end: 106)]
        #expect(Board.followAim(hunks) == LineRange(start: 106, end: 106), "a removed import first, the fix last")
        #expect(Board.followAim([LineRange(start: 5, end: 9), LineRange(start: 40, end: 40)]) == LineRange(start: 5, end: 9))
        #expect(Board.followAim([]) == nil)
    }

    @Test func longTerminalTextKeepsItsHeadAndTailAndSaysHowMuchWasLeftOut() {
        let lines = (1...50).map { "line \($0)" }
        #expect(TerminalExcerpt.trim(lines, head: 2, tail: 3) == ["line 1", "line 2", "… 45 lines omitted …", "line 48", "line 49", "line 50"])
        #expect(TerminalExcerpt.trim(Array(lines.prefix(6)), head: 2, tail: 3) == Array(lines.prefix(6)), "one more line than fits beats a marker")
        #expect(TerminalExcerpt.lines("\n\n  a  \nb\n\n") == ["  a", "b"])
    }

    /// `pytest -q` with two failures, as the debugger study's run printed it (2246 tests).
    static let pytestRun: [String] = {
        var lines = (1...21).map { row in String(repeating: row == 2 ? "..FF.." : "......", count: 17) + " [\(String(format: "%3d", row * 100 / 21))%]" }
        lines += [
            "=================================== FAILURES ===================================",
            "___________________________ test_nargs_star_ordering ___________________________",
            "",
            "runner = <click.testing.CliRunner object at 0x1115d3e30>",
            "",
            "    def test_nargs_star_ordering(runner):",
            "        @click.command()",
            "        @click.argument(\"a\", nargs=-1)",
            "        @click.argument(\"b\")",
            "        @click.argument(\"c\")",
            "        def cmd(a, b, c):",
            "            for arg in (a, b, c):",
            "                click.echo(arg)",
            "",
            "        result = runner.invoke(cmd, [\"a\", \"b\", \"c\"])",
            ">       assert result.output.splitlines() == [\"('a',)\", \"b\", \"c\"]",
            "E       assert [\"('a',)\", 'c', 'b'] == [\"('a',)\", 'b', 'c']",
            "E",
            "E         At index 1 diff: 'c' != 'b'",
            "E         Use -v to get more diff",
            "",
            "tests/test_arguments.py:932: AssertionError",
            "___________________ test_nargs_specified_plus_star_ordering ____________________",
            "",
            "runner = <click.testing.CliRunner object at 0x11161a3c0>",
            "",
            "    def test_nargs_specified_plus_star_ordering(runner):",
            "        @click.command()",
            "        @click.argument(\"a\", nargs=-1)",
            "        @click.argument(\"b\")",
            "        @click.argument(\"c\", nargs=2)",
            "        def cmd(a, b, c):",
            "            for arg in (a, b, c):",
            "                click.echo(arg)",
            "",
            "        result = runner.invoke(cmd, [\"a\", \"b\", \"c\", \"d\", \"e\", \"f\"])",
            ">       assert result.output.splitlines() == [\"('a', 'b', 'c')\", \"d\", \"('e', 'f')\"]",
            "E       assert ['Usage: cmd ...an iterable.'] == [\"('a', 'b', ... \"('e', 'f')\"]",
            "E",
            "E         At index 0 diff: 'Usage: cmd [OPTIONS] [A]... B C...' != \"('a', 'b', 'c')\"",
            "",
            "tests/test_arguments.py:945: AssertionError",
            "=========================== short test summary info ============================",
            "FAILED tests/test_arguments.py::test_nargs_star_ordering - assert [\"('a',)\", 'c', 'b'] == [\"('a',)\", 'b', 'c']",
            "FAILED tests/test_arguments.py::test_nargs_specified_plus_star_ordering - assert ['Usage: cmd ...an iterable.'] == [\"('a', 'b', ... \"('e', 'f')\"]",
            "2 failed, 2242 passed, 25 skipped, 1 xfailed in 4.95s",
        ]
        return lines
    }()

    @Test func aLongTestRunKeepsItsFailuresOverItsProgressDots() {
        let trimmed = TerminalExcerpt.trim(Self.pytestRun, head: 10, tail: 30)
        #expect(trimmed.first == "… 21 progress lines omitted …", "no row of dots survives")
        #expect(trimmed.count <= 40 + 3, "the same budget, plus a marker per gap")
        for line in ["___________________________ test_nargs_star_ordering ___________________________",
                     ">       assert result.output.splitlines() == [\"('a',)\", \"b\", \"c\"]",
                     "E       assert [\"('a',)\", 'c', 'b'] == [\"('a',)\", 'b', 'c']",
                     "E         At index 1 diff: 'c' != 'b'",
                     "tests/test_arguments.py:932: AssertionError",
                     "E       assert ['Usage: cmd ...an iterable.'] == [\"('a', 'b', ... \"('e', 'f')\"]",
                     "tests/test_arguments.py:945: AssertionError"] {
            #expect(trimmed.contains(line), "the first failure's body and both assertions stay: \(line)")
        }
        #expect(Array(trimmed.suffix(4)) == Array(Self.pytestRun.suffix(4)), "the summary ends it")
        #expect(trimmed.contains { $0.hasPrefix("… ") && $0.hasSuffix(" lines omitted …") && !$0.contains("progress") }, "the test source between is what goes")
        // Short enough once its progress rows go: the rest whole.
        let short = Array(Self.pytestRun.prefix(21)) + Array(Self.pytestRun.suffix(30))
        #expect(TerminalExcerpt.trim(short, head: 10, tail: 30) == ["… 21 progress lines omitted …"] + Array(Self.pytestRun.suffix(30)))
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
        let first = tracker.finished(exit: 1, durationNanos: 42_000_000_000, at: t0.addingTimeInterval(44), shellAtPrompt: true, agentReporting: false)
        #expect(first == TerminalCommand(command: "go test ./...", exit: 1, durationMs: 42_000))
        // The framework's prompt title again, well after the prompt (a redraw): still not a command.
        tracker.title("zsh in app", at: t0.addingTimeInterval(44.01), promptTitle: "~/src/app")
        tracker.title("zsh in app", at: t0.addingTimeInterval(50), promptTitle: "~/src/app")
        tracker.running(program: "make")
        #expect(tracker.finished(exit: 0, durationNanos: 1_000_000, at: t0.addingTimeInterval(60), shellAtPrompt: true, agentReporting: false)?.command == "make",
                "no title: the program seen running")
        #expect(TerminalCommandTracker.promptTitle(cwd: "/Users/me/src/app", home: "/Users/me") == "~/src/app")
        #expect(TerminalCommandTracker.promptTitle(cwd: "/tmp/x", home: "/Users/me") == "/tmp/x")
    }

    @Test func aCommandStartsOnceItsTitleComesAndEndsAtTheNextPrompt() {
        // The header's status (the previous command's exit and duration) clears as one starts.
        var tracker = TerminalCommandTracker()
        let t0 = Date()
        tracker.prompt(at: t0)
        let promptTitle = tracker.title("~/src/app", at: t0.addingTimeInterval(0.01), promptTitle: "~/src/app")
        #expect(!promptTitle, "the prompt's own title")
        let started = tracker.title("aider --model x", at: t0.addingTimeInterval(2), promptTitle: "~/src/app")
        #expect(started)
        #expect(tracker.running == "aider --model x")
        let retitled = tracker.title("aider: thinking", at: t0.addingTimeInterval(3), promptTitle: "~/src/app")
        #expect(!retitled, "the program retitling isn't a new command")
        _ = tracker.finished(exit: 0, durationNanos: 1_000_000, at: t0.addingTimeInterval(9), shellAtPrompt: true, agentReporting: false)
        #expect(tracker.running == nil)
    }

    @Test func anAgentTUIsOwnMarksAndSpinnerTitlesAreNotCommandsButTheShellsFailureStillIs() {
        var tracker = TerminalCommandTracker()
        let t0 = Date()
        tracker.prompt(at: t0)
        tracker.title("omp", at: t0.addingTimeInterval(2), promptTitle: "~/src/app")
        tracker.title("π ⠸ Find where Click decides boolean flags", at: t0.addingTimeInterval(5), promptTitle: "~/src/app")
        // omp's own C/D pair while it holds the foreground, and one while it reports a lifecycle.
        #expect(tracker.finished(exit: 0, durationNanos: 0, at: t0.addingTimeInterval(6), shellAtPrompt: false, agentReporting: false) == nil)
        #expect(tracker.finished(exit: 0, durationNanos: 0, at: t0.addingTimeInterval(7), shellAtPrompt: true, agentReporting: true) == nil)
        // omp exits and released its lifecycle: the shell's D names the command it started.
        #expect(tracker.finished(exit: 0, durationNanos: 90_000_000_000, at: t0.addingTimeInterval(92), shellAtPrompt: true, agentReporting: false)
                == TerminalCommand(command: "omp", exit: 0, durationMs: 90_000))
        tracker.title("false", at: t0.addingTimeInterval(95), promptTitle: "~/src/app")
        #expect(tracker.finished(exit: 1, durationNanos: 3_000_000, at: t0.addingTimeInterval(95.01), shellAtPrompt: true, agentReporting: false)
                == TerminalCommand(command: "false", exit: 1, durationMs: 3))
    }

    @Test func statusShowsOnlyFailuresAndLongRunsAndTheMarkerSaysWhatRan() {
        #expect(TerminalCommand(command: "ls", exit: 0, durationMs: 40).status == nil)
        #expect(TerminalCommand(command: "false", exit: 1, durationMs: 40).status == "exit 1")
        #expect(TerminalCommand(command: "go test", exit: 1, durationMs: 42_300).status == "exit 1 · 42 s")
        #expect(TerminalCommand(command: "make", exit: 0, durationMs: 182_000).status == "3 min 2 s")
        #expect(TerminalCommand(command: "go test ./...", exit: 1, durationMs: 42_000).noticeMessage == "go test ./... exited 1 · 42 s")
        #expect(TerminalCommand(exit: 0, durationMs: 3_600_000 + 300_000).noticeMessage == "Command finished · 1 h 5 min")
    }

    @Test func theMarkerNamesTheCommandThatRanLongNotACompoundLinesSetup() {
        func name(_ line: String) -> String { TerminalCommand.significant(line) }
        #expect(name("export PATH=$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH; cargo build --release --offline -j 2")
                == "cargo build --release --offline -j 2")
        #expect(name("cd crates/x && cargo test") == "cargo test")
        #expect(name("clear; RUST_BACKTRACE=1 cargo test depth") == "cargo test depth", "env assignments before the command go too")
        #expect(name("cd x && env FOO=1 make -j4 && echo done") == "make -j4 && echo done", "what follows the command stays")
        #expect(name("echo \"a; cd b\" && make") == "echo \"a; cd b\" && make", "operators inside quotes don't split")
        #expect(name("cd /tmp") == "cd /tmp", "all setup: the line as it is")
        #expect(name("cargo test | tee log") == "cargo test | tee log")
        let long = TerminalCommand(command: "export PATH=$HOME/.rustup/bin:$PATH; cargo build --release", exit: 0, durationMs: 35_900)
        #expect(long.noticeMessage == "cargo build --release finished · 35 s")
        let now = Date()
        #expect(TerminalCommand.bellMessage(program: nil, shell: "zsh", last: TerminalCommandLog.Entry(command: TerminalCommand(command: "cd app && make test", exit: 1), finishedAt: now), at: now) == "Bell after `make test`")
    }

    /// `clear; cargo build` with two E0277s and an E0308, as rustc prints them.
    static let cargoBuild: [String] = {
        var lines = ["   Compiling fd-find v10.2.0 (/private/tmp/fd)"]
        lines += [
            "error[E0308]: mismatched types",
            "   --> src/cli.rs:412:24",
            "    |",
            "412 |         max_depth: self.max_depth.or(self.exact_depth),",
            "    |                        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ expected `Option<usize>`, found `Option<u64>`",
            "    |",
            "    = note: expected enum `Option<usize>`",
            "               found enum `Option<u64>`",
            "",
        ]
        for (file, line, macro) in [("src/error.rs:9:52", "src/walk.rs:228:33", "print_error"), ("src/error.rs:9:52", "src/main.rs:72:9", "print_error")] {
            lines += [
                "error[E0277]: the trait bound `u64: From<usize>` is not satisfied",
                "   --> \(file)",
                "    |",
                "9   |         eprintln!(\"[fd error]: {}\", format!($($arg)*).len() as u64);",
                "    |                                                    ^^^^^ the trait `From<usize>` is not implemented for `u64`",
                "    |",
                "   ::: \(line)",
                "    |",
                "228 |               \(macro)!(",
                "    |  _____________-",
                "229 | |                 \"Search path '{}' is not a directory.\",",
                "...",
                "235 | |             );",
                "    | |_____________- in this macro invocation",
                "    |",
                "    = help: the following other types implement trait `From<T>`:",
                "              `u64` implements `From<Char>`",
                "              `u64` implements `From<bool>`",
                "              `u64` implements `From<u16>`",
                "              `u64` implements `From<u32>`",
                "              `u64` implements `From<u8>`",
                "    = note: required for `usize` to implement `Into<u64>`",
                "    = note: this error originates in the macro `\(macro)` (in Nightly builds, run with -Z macro-backtrace for more info)",
                "",
            ]
        }
        lines += [
            "Some errors have detailed explanations: E0277, E0308.",
            "For more information about an error, try `rustc --explain E0277`.",
            "error: could not compile `fd-find` (bin \"fd\") due to 3 previous errors",
        ]
        return lines
    }()

    @Test func aCompilersLocationLinesStayAndItsEllipsisIsNoProgress() {
        let trimmed = TerminalExcerpt.trim(Self.cargoBuild, head: 10, tail: 30)
        #expect(Self.cargoBuild.count > 41, "long enough to trim")
        let locations = Self.cargoBuild.filter { $0.contains("--> ") || $0.contains("::: ") }
        #expect(locations.count == 5)
        for line in locations + Self.cargoBuild.filter({ $0.hasPrefix("error") }) {
            #expect(trimmed.contains(line), "every error and where it is: \(line)")
        }
        #expect(!trimmed.contains { $0.contains("progress") }, "rustc's `...` leaves out source lines; it isn't progress")
        #expect(TerminalExcerpt.trim(["...", "ok"] + (1...50).map { "line \($0)" }, head: 2, tail: 3).first == "...")
        var run = (1...50).map { "line \($0)" }
        run[25] = "      at ./tests/tests.rs:1431:8"
        #expect(TerminalExcerpt.trim(run, head: 10, tail: 3).contains(run[25]), "a stack frame at a file:line:col is a failure line")
    }

    @Test func theCommandLogFindsABlockByItsCommandsLineAfterItsPromptScrolledAwayOrClearWipedIt() {
        let jq = TerminalCommand(command: "jq -r .status api.jsonl", exit: 0, durationMs: 120)
        let grep = TerminalCommand(command: "git grep -n rateKey", exit: 0, durationMs: 30)
        let again = TerminalCommand(command: "jq -r .status api.jsonl", exit: 5, durationMs: 90)
        var log = TerminalCommandLog()
        for command in [jq, grep, again] { log.append(command, at: Date()) }
        // The terminal's text to the cursor: older output, then each block under its command line.
        let text = ["old output", "❯ jq -r .status api.jsonl", "200", "500", "", "~/app on main", "❯ git grep -n rateKey",
                    "server/claims.ts:241: rateKey", "", "~/app on main", "❯ jq -r .status api.jsonl", "jq: error", "", "~/app on main", "❯ "]
        #expect(log.positions(in: text) == [-1: 10, -2: 6, -3: 1], "the same command twice: each block its own line")
        #expect(log.block(holding: 3, in: text) == -3, "the first jq block, however far its prompt row scrolled")
        #expect(log.block(holding: 7, in: text) == -2)
        #expect(log.block(holding: 11, in: text) == -1)
        #expect(log.block(holding: 0, in: text) == nil && log.block(holding: 6, in: text) == nil, "older text and a command line are no block")
        #expect(log.index(of: jq) == -3 && log.index(of: again) == -1 && log.index(of: TerminalCommand(command: "ls")) == nil)
        #expect(log.output(-3, in: text, promptAbove: 2) == 2..<4, "less the blank line and the path line a prompt shows above its input line")
        #expect(log.output(-1, in: text, promptAbove: 2) == 11..<12)
        // Scrollback trimmed past the first jq: it and anything older are gone.
        #expect(log.positions(in: Array(text.dropFirst(2))) == [-1: 8, -2: 4])
        // `clear; cargo build` wiped the screen with its own command line.
        let build = TerminalCommand(command: "clear; cargo build", exit: 101, durationMs: 4_200)
        log.append(build, at: Date())
        let cleared = ["error[E0277]: the trait bound `u64: From<usize>` is not satisfied", "   --> src/error.rs:9:52", "error: could not compile `fd-find`", "", "❯ "]
        #expect(log.positions(in: cleared) == [-1: -1])
        #expect(log.block(holding: 1, in: cleared) == -1, "its output from the top")
        #expect(log.output(-2, in: cleared, promptAbove: 0) == nil, "what came before the clear is gone")
        #expect(TerminalBlocks.isCommandLine("❯ cmake", of: "make") == false && TerminalBlocks.isCommandLine("make", of: "make"), "whole words")
    }

    @Test func theLiveScreenJoinsRowsByTheTerminalsOwnWrapFlags() {
        // pytest cuts its short-summary rows at the width: two FAILED rows of exactly 20 columns.
        let history = "old 0123456789abcdef\nnext\nFAILED a.py::t - Ass\nFAILED b.py::u - Err\n0123456789abcdefghij\nwrapped rest\nwant \"a b w\n│x\n$\n\n"
        func read(screen: [TerminalTail.ScreenRow]) -> [String] {
            var tail = TerminalTail(limit: 50, columns: 20, screen: screen)
            tail.append(Data(history.utf8))
            return tail.finish().rows
        }
        let rows = ["FAILED a.py::t - Ass", "FAILED b.py::u - Err", "0123456789abcdefghij", "wrapped rest", "want \"a b w", "│x", "$", ""]
        let hard = rows.map { TerminalTail.ScreenRow(text: $0, wraps: false) }
        #expect(read(screen: hard) == ["old 0123456789abcdefnext", "FAILED a.py::t - Ass", "FAILED b.py::u - Err", "0123456789abcdefghij", "wrapped rest", "want \"a b w", "│x", "$"],
                "on the screen no row joins that the terminal didn't wrap; above it the guess stands")
        var soft = hard
        soft[4].wraps = true
        #expect(read(screen: soft).suffix(3) == ["wrapped rest", "want \"a b w│x", "$"], "one the terminal wrapped joins, border or not")
        #expect(read(screen: []) == ["old 0123456789abcdefnext", "FAILED a.py::t - Ass", "FAILED b.py::u - Err0123456789abcdefghijwrapped rest", "want \"a b w", "│x", "$"],
                "without the screen: the guess, which keeps rows that start alike apart but joins every other full row")
        var moved = hard
        moved[0].text = "something else"
        #expect(read(screen: moved) == read(screen: []), "a screen that doesn't read as the history's end changes nothing")
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
        board.terminalBlockIndex = { id, command in id == shell && command.command == "go test ./..." ? -3 : nil }
        let output = (1...60).map { "ok \($0)" }.joined(separator: "\n")
        try board.stage(.terminal(object: shell, text: output, part: .command, command: TerminalCommand(command: "go test ./...", exit: 1, durationMs: 42_000)))
        try board.stage(.object(shell))
        let context = await board.drain().context
        #expect(context.contains("[1] command `go test ./...` · exit 1 · 42 s · output of terminal tile \(shell) \"go · ~/src/app\" · read it: canvas agent.read --target \(shell) --block -3"),
                "the call that reads that block, counted from the terminal's newest command")
        #expect(context.contains("    ok 10\n    … 20 lines omitted …\n    ok 31"))
        #expect(context.contains("[2] terminal \(shell) \"go · ~/src/app\""))
        #expect(context.contains("    README.md"))
        #expect(context.contains("canvas agent.read --target <id>"))
        #expect(!context.contains("canvas get <id> --as graph"), "only terminals mentioned")
    }
}
