import Foundation
import Testing
import CanvasCore

struct TerminalReferencesTests {
    func refs(_ text: String) -> [String] {
        TerminalReferences.find(in: text).map { "\($0.path) \($0.lines.start)-\($0.lines.end)" }
    }

    @Test func findsTheFormsAgentsAndToolsWrite() {
        #expect(refs("see `src/foo.ts:42` and src/bar.ts:42:7.") == ["src/foo.ts 42-42", "src/bar.ts 42-42"])
        #expect(refs("supervisor.ts:486, lib/x.py:10-20") == ["supervisor.ts 486-486", "lib/x.py 10-20"])
        #expect(refs("foo.rs#L10-20 and bar.rs#L3-L5 and baz.go#L7") == ["foo.rs 10-20", "bar.rs 3-5", "baz.go 7-7"])
        #expect(refs("/Users/me/app/main.swift:3 ~/x.py:9 ../up/a.c:1") == ["/Users/me/app/main.swift 3-3", "~/x.py 9-9", "../up/a.c 1-1"])
        #expect(refs("bin/canvas:12") == ["bin/canvas 12-12"], "a path with a slash needs no extension")
    }

    @Test func leavesUrlsTimesAndVersionsAlone() {
        #expect(refs("https://example.com:443/a.js:3 localhost:3000 at 12:30 v1.2:3 Makefile:4").isEmpty)
        #expect(refs("foo.ts:0 foo.ts:12abc").isEmpty)
    }

    @Test func aReversedRangeIsTheStartLine() {
        #expect(refs("a.ts:20-10") == ["a.ts 20-20"])
    }

    @Test func referenceAtAnOffset() {
        let text = "error in src/foo.ts:42 then lib/b.ts:3"
        #expect(TerminalReferences.reference(in: text, at: 12)?.path == "src/foo.ts")
        #expect(TerminalReferences.reference(in: text, at: 21)?.lines.start == 42, "the line number is part of it")
        #expect(TerminalReferences.reference(in: text, at: 3) == nil)
    }

    @Test func resolvesAgainstDirectoriesInOrder() {
        let files: Set<String> = ["/cwd/src/a.ts", "/root/src/a.ts", "/root/only.ts", "/home/me/x.py", "/abs/b.swift", "/root/lib/c.rs"]
        func resolve(_ path: String) -> String? {
            TerminalReferences.resolve(path, directories: ["/cwd", "/props", "/root"], home: "/home/me", isFile: files.contains)
        }
        #expect(resolve("src/a.ts") == "/cwd/src/a.ts", "the reported cwd wins")
        #expect(resolve("only.ts") == "/root/only.ts", "then the board root")
        #expect(resolve("~/x.py") == "/home/me/x.py")
        #expect(resolve("/abs/b.swift") == "/abs/b.swift")
        #expect(resolve("b/lib/c.rs") == "/root/lib/c.rs", "a diff's b/ prefix")
        #expect(resolve("missing.ts") == nil)
        #expect(resolve("/abs/missing.swift") == nil)
    }

    /// Agents write `core.py:2535` for `src/click/core.py:2535` before they read the skill.
    @Test func resolvesFileNamesAmongTheRootsFilesNearestTheCwd() {
        let listed = [
            "src/click/core.py", "src/click/parser.py", "tests/test_core.py", "lib/helpers.py", "app/helpers.py",
            "pkg/a/util.py", "pkg/b/util.py", "docs/util.py", "src/click/README.md", "gone.py",
        ]
        let files = Set(listed.filter { $0 != "gone.py" }.map { "/root/" + $0 } + ["/cwd/parser.py"])
        func resolve(_ path: String, cwd: String = "/root") -> String? {
            TerminalReferences.resolve(path, directories: [cwd, "/root"], home: "/home/me", isFile: files.contains,
                                       listed: ("/root", FileIndex(paths: listed)), near: cwd)
        }
        #expect(resolve("core.py") == "/root/src/click/core.py", "a unique name")
        #expect(resolve("click/core.py") == "/root/src/click/core.py", "a trailing part of the path")
        #expect(resolve("./click/core.py") == "/root/src/click/core.py")
        #expect(resolve("lick/core.py") == nil, "whole path components only")
        #expect(resolve("parser.py", cwd: "/cwd") == "/cwd/parser.py", "a directory hit comes before the listing")
        #expect(resolve("gone.py") == nil, "listed but no longer on disk")
        #expect(resolve("helpers.py") == nil, "lib/ and app/ are equally near the root: ambiguous, no underline")
        #expect(resolve("util.py") == "/root/docs/util.py", "one directory down beats two")
        #expect(resolve("util.py", cwd: "/root/pkg/a") == "/root/pkg/a/util.py", "the one in the cwd")
        #expect(resolve("util.py", cwd: "/root/pkg/b/sub") == "/root/pkg/b/util.py", "the nearest one up")
        #expect(resolve("util.py", cwd: "/root/pkg") == nil, "pkg/a and pkg/b tie")
        #expect(resolve("a/util.py") == "/root/pkg/a/util.py", "a longer suffix narrows it")
        #expect(resolve("../core.py") == nil, "never climbs out")
        #expect(TerminalReferences.resolve("core.py", directories: ["/root"], home: "/home/me", isFile: files.contains) == nil, "no listing, no lookup")
    }
}

@MainActor
struct TerminalBoardTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-tests-\(UUID().uuidString)")

    func makeBoard() -> Board {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Board(id: "brd_test", root: root)
    }

    @Test func openCodeSelectsTheTileAlreadyShowingThatRange() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object([:]))
        let path = root.appendingPathComponent("src/a.ts").path
        let first = board.openCode(path: path, lines: LineRange(start: 42, end: 42), beside: terminal.id)
        #expect(first.created)
        #expect(board.objects[first.id]?.props["path"]?.string == "src/a.ts", "stored board-relative")
        let again = board.openCode(path: path, lines: LineRange(start: 42, end: 42), beside: terminal.id)
        #expect(!again.created && again.id == first.id)
        let other = board.openCode(path: path, lines: LineRange(start: 7, end: 9), beside: terminal.id)
        #expect(other.created && other.id != first.id, "another range of the same file is another tile")
    }

    @Test func openCodeIgnoresFollowTiles() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object([:]))
        let range: JSONValue = .object(["start": .number(5), "end": .number(5)])
        let follow = board.create(type: .code, props: .object(["path": .string("a.ts"), "range": range, "followOf": .string(terminal.id)]))
        let opened = board.openCode(path: root.appendingPathComponent("a.ts").path, lines: LineRange(start: 5, end: 5), beside: terminal.id)
        #expect(opened.created && opened.id != follow.id, "the follow tile belongs to its agent")
    }

    @Test func terminalNoticesCoalesce() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object([:]))
        var events = 0
        board.onEvent = { if case .attentionChanged = $0 { events += 1 } }
        #expect(board.raiseTerminalNotice(terminal.id, message: "Bell", bell: true))
        #expect(!board.raiseTerminalNotice(terminal.id, message: "Bell", bell: true), "a second bell changes nothing")
        #expect(board.raiseTerminalNotice(terminal.id, message: "Claude: Needs permission", bell: false))
        #expect(!board.raiseTerminalNotice(terminal.id, message: "Bell", bell: true), "a bell never replaces a notification")
        #expect(!board.raiseTerminalNotice(terminal.id, message: "Claude: Needs permission", bell: false))
        #expect(events == 2)
        #expect(board.attention[terminal.id]?.message == "Claude: Needs permission")
        #expect(board.attention[terminal.id]?.raisedBy == nil)
        board.clearAttention(terminal.id)
        #expect(board.raiseTerminalNotice(terminal.id, message: "Bell", bell: true), "after the user looked, a bell raises again")
    }

    @Test func noticesOnlyForTerminals() {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("x")]))
        #expect(!board.raiseTerminalNotice(note.id, message: "Bell", bell: true))
        #expect(!board.raiseTerminalNotice("obj_missing", message: "Bell", bell: true))
    }

    @Test func noticesFromAReportingAgentRaiseNothingUntilItExits() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["command": .array([])]))
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .done, message: nil, seq: 1, source: "canvas-omp")
        #expect(!board.raiseTerminalNotice(terminal.id, message: "omp: Complete", bell: false), "its badge already says done")
        #expect(board.attention[terminal.id] == nil)
        try board.releaseAgent(tile: terminal.id)
        #expect(board.raiseTerminalNotice(terminal.id, message: "Build: done", bell: false), "a plain shell again")
    }

    @Test func anApprovalStaysBlockedUntilItsOwnCallFinishes() throws {
        let board = makeBoard()
        let tile = board.create(type: .terminal, props: .object([:])).id
        var seq = 0
        func report(_ state: LifecycleState, _ message: String? = nil, call: String? = nil) throws {
            seq += 1
            try board.reportLifecycle(tile: tile, kind: "codex", state: state, message: message, seq: seq, source: "canvas-codex", call: call)
        }
        func shown() -> (state: String?, message: String?) {
            let lifecycle = board.objects[tile]?.props["lifecycle"]
            return (lifecycle?["state"]?.string, lifecycle?["message"]?.string)
        }
        try report(.working)
        try report(.blocked, "run machine-ok?", call: "a")
        try report(.blocked, "run pnpm --version?", call: "b")
        #expect(shown() == ("blocked", "run machine-ok?"), "the approval on screen is the first one asked")
        try report(.working, call: "subagent-read")
        try report(.working, call: "sibling")
        #expect(shown() == ("blocked", "run machine-ok?"), "other calls finishing don't answer it")
        try report(.working, call: "a")
        #expect(shown() == ("blocked", "run pnpm --version?"), "the queued approval comes up next")
        try report(.working, call: "b")
        #expect(shown().state == "working")

        // A call finishing reported late (async hooks) still ends its own wait.
        try report(.blocked, "edit a.ts?", call: "c")
        let late = seq
        try report(.blocked, "edit b.ts?", call: "d")
        try board.reportLifecycle(tile: tile, kind: "codex", state: .working, message: nil, seq: late, source: "canvas-codex", call: "c")
        try report(.working, call: "d")
        #expect(shown().state == "working", "c's late completion was not lost")

        // Stop, an interrupt, or a new prompt ends every wait.
        try report(.blocked, "edit c.ts?", call: "e")
        try report(.idle)
        try report(.working, call: "f")
        #expect(shown().state == "working")
        try report(.blocked, "edit d.ts?", call: "g")
        try report(.working)
        try report(.working, call: "h")
        #expect(shown().state == "working")
    }

    @Test func anAgentThatExitedIsNotResumed() throws {
        let board = makeBoard()
        let tile = board.create(type: .terminal, props: .object([:])).id
        try board.reportSession(tile: tile, kind: "codex", sessionId: "thread-1", sessionPath: nil)
        try board.reportLifecycle(tile: tile, kind: "codex", state: .idle, message: nil, seq: 1, source: "canvas-codex")
        #expect(board.objects[tile]?.props["agent"]?["sessionId"] == .string("thread-1"), "a running agent is resumed after a reboot")
        try board.releaseAgent(tile: tile)
        #expect(board.objects[tile]?.props["agent"] == nil, "quit: the tile restores as a plain shell")
        #expect(board.objects[tile]?.props["lifecycle"] == nil)
    }

    @Test func noticeMessages() {
        #expect(Board.noticeMessage(title: "Claude", body: "Needs permission") == "Claude: Needs permission")
        #expect(Board.noticeMessage(title: "", body: "Build finished") == "Build finished")
        #expect(Board.noticeMessage(title: "Done", body: " ") == "Done")
    }
}

struct AgentResumeTests {
    @Test func eachAgentResumesItsOwnWay() {
        #expect(AgentResume.argv(kind: "omp", sessionId: "s1") == ["omp", "--resume=s1"])
        #expect(AgentResume.argv(kind: "claude", sessionId: "u-1") == ["claude", "--resume", "u-1"])
        #expect(AgentResume.argv(kind: "codex", sessionId: "t-1") == ["codex", "resume", "t-1"])
        #expect(AgentResume.argv(kind: "aider", sessionId: "x") == nil)
    }
}

struct GhosttyConfigTests {
    typealias Entry = GhosttyConfig.Entry

    func load(_ files: [String: String], top: [String]) -> GhosttyConfig {
        GhosttyConfig.load(files: top.map { URL(fileURLWithPath: $0) }) { files[$0.standardizedFileURL.path] }
    }

    @Test func includesLoadAfterEveryTopLevelFileRelativeToTheirFile() {
        let config = load([
            "/x/ghostty/config": "font-size = 20\nconfig-file = ?local.conf\nconfig-file = ?missing.conf\n# comment\nkeybind = shift+enter=text:\\n",
            "/x/ghostty/local.conf": "font-size = 22\nconfig-file = ../ghostty/config",
            "/support/config": "font-size = 21",
        ], top: ["/x/ghostty/config", "/support/config"])
        #expect(config.entries == [Entry("font-size", "20"), Entry("keybind", "shift+enter=text:\\n"), Entry("font-size", "21"), Entry("font-size", "22")])
        #expect(GhosttyConfig.value("font-size", in: config.entries) == "22", "an include loads last, and a cycle stops")
    }

    @Test func themes() {
        #expect(GhosttyConfig.themes("Hardcore") == ("Hardcore", "Hardcore"))
        #expect(GhosttyConfig.themes("\"Catppuccin Mocha\"") == ("Catppuccin Mocha", "Catppuccin Mocha"))
        #expect(GhosttyConfig.themes("dark:B, light:A") == ("A", "B"))
        #expect(GhosttyConfig.themes("dark:B") == ("B", "B"))
        let config = load(["/c": "theme = one\ntheme = light:A,dark:B"], top: ["/c"])
        #expect(config.lightTheme == "A" && config.darkTheme == "B", "the last theme wins")
        #expect(config.entries.isEmpty)
        let dirs = [URL(fileURLWithPath: "/user/themes"), URL(fileURLWithPath: "/app/themes")]
        #expect(GhosttyConfig.themeFile("A", directories: dirs, isFile: { $0 == "/app/themes/A" })?.path == "/app/themes/A")
        #expect(GhosttyConfig.themeFile("A", directories: dirs, isFile: { _ in true })?.path == "/user/themes/A", "the user's theme shadows Ghostty's")
    }

    @Test func userSettingsBeatTheThemeAndCanvasKeepsItsOwn() {
        let config = GhosttyConfig(entries: [Entry("background", "#101010"), Entry("command", "fish"), Entry("background-opacity", "0.8"), Entry("font-size", "24"),
                                             Entry("background-image", "~/wall.png"), Entry("font-family", "JetBrains Mono")])
        let settings = config.settings(theme: [Entry("background", "#ffffff"), Entry("palette", "0=#000000")])
        #expect(GhosttyConfig.value("background", in: settings) == "#101010")
        #expect(GhosttyConfig.value("font-family", in: settings) == "JetBrains Mono")
        #expect(GhosttyConfig.value("command", in: settings) == nil)
        #expect(GhosttyConfig.value("background-opacity", in: settings) == "1")
        #expect(GhosttyConfig.value("font-size", in: settings) == nil, "tile sizes assume Ghostty's default size; zoom scales text")
        #expect(GhosttyConfig.value("background-image", in: settings) == nil, "cards and renders can't draw it")
        #expect(settings.first == Entry("background", "#ffffff"), "the theme comes first")
    }

    @Test func repeatableValuesHonorResets() {
        let settings = [Entry("font-family", "A"), Entry("font-family", ""), Entry("font-family", "\"B C\""), Entry("font-family", "D")]
        #expect(GhosttyConfig.values("font-family", in: settings) == ["B C", "D"])
        #expect(GhosttyConfig.value("font-size", in: [Entry("font-size", "20"), Entry("font-size", "")]) == nil)
    }

    @Test func defaultFilesFollowXdg() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(GhosttyConfig.defaultFiles(home: home, environment: [:]).map(\.path) == [
            "/Users/me/.config/ghostty/config", "/Users/me/.config/ghostty/config.ghostty",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config", "/Users/me/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ])
        #expect(GhosttyConfig.defaultFiles(home: home, environment: ["XDG_CONFIG_HOME": "/tmp/x"]).first?.path == "/tmp/x/ghostty/config")
    }

    @Test func appActionKeybindsNeverReachGhosttyAndNewWindowTabSplitOpenATerminal() {
        typealias Chord = GhosttyConfig.KeyChord
        let config = load(["/c": """
            keybind = super+t=new_window
            keybind = ctrl+shift+enter=new_split:right
            keybind = super+w=close_surface
            keybind = super+==new_tab
            keybind = global:super+key_n=new_tab
            keybind = super+shift+w=close_window
            keybind = super+ctrl+f=toggle_fullscreen
            keybind = ctrl+a>n=new_tab
            keybind = ctrl+shift+x=text:hello
            keybind = super+k=clear_screen
            """], top: ["/c"])
        #expect(GhosttyConfig.values("keybind", in: config.settings(theme: [])) == ["ctrl+shift+x=text:hello", "super+k=clear_screen"],
                "only bindings the library performs itself are handed to it")
        #expect(config.remaps == [
            Chord(.command, "t"): .newTerminal, Chord([.control, .shift], "enter"): .newTerminal, Chord(.command, "w"): .closeTerminal,
            Chord(.command, "="): .newTerminal, Chord(.command, "n"): .newTerminal,
        ])
        #expect(config.appKeybinds.filter { $0.action == nil || $0.chord == nil }.map(\.entry.value) == [
            "super+shift+w=close_window", "super+ctrl+f=toggle_fullscreen", "ctrl+a>n=new_tab",
        ], "dropped: actions Canvas has no equivalent of, and a sequence it can't match")
    }

    @Test func aLaterBindingOfTheSameChordOrAClearUndoesARemap() {
        let rebound = load(["/c": "keybind = super+t=new_window\nkeybind = super+d=new_split\nkeybind = super+t=unbind"], top: ["/c"])
        #expect(rebound.remaps == [GhosttyConfig.KeyChord(.command, "d"): .newTerminal])
        #expect(GhosttyConfig.values("keybind", in: rebound.settings(theme: [])) == ["super+t=unbind"])
        let cleared = load(["/c": "keybind = super+t=new_window\nkeybind = clear\nkeybind = ctrl+shift+t=new_tab"], top: ["/c"])
        #expect(cleared.remaps == [GhosttyConfig.KeyChord([.control, .shift], "t"): .newTerminal])
    }
}
