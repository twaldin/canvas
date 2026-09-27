import Foundation
import Testing
import CanvasCore
import Markdown

struct NoteFenceTests {
    @Test func excerptWithLineRange() {
        let fence = NoteFence(info: "ts file=src/app.ts#L10-40")
        #expect(fence == NoteFence(language: "ts", path: "src/app.ts", lines: LineRange(start: 10, end: 40)))
        #expect(fence.mode == .excerpt)
    }

    @Test func lineRangeForms() {
        #expect(NoteFence(info: "file=a.ts#L7").lines == LineRange(start: 7, end: 7))
        #expect(NoteFence(info: "file=a.ts#L7-L9").lines == LineRange(start: 7, end: 9))
        #expect(NoteFence(info: "file=a.ts#7-9").lines == LineRange(start: 7, end: 9))
        // A backwards or zero range is no range, and doesn't leak into the path.
        #expect(NoteFence(info: "file=a.ts#L9-7") == NoteFence(path: "a.ts"))
        #expect(NoteFence(info: "file=a.ts#L0") == NoteFence(path: "a.ts"))
    }

    @Test func symbolWithAndWithoutFile() {
        let scoped = NoteFence(info: "swift file=Sources/Board.swift symbol=Board.update")
        #expect(scoped.path == "Sources/Board.swift")
        #expect(scoped.symbol == "Board.update")
        #expect(scoped.mode == .excerpt)
        let workspace = NoteFence(info: "ts symbol=restoreSnapshot")
        #expect(workspace.path == nil)
        #expect(workspace.symbol == "restoreSnapshot")
        #expect(workspace.mode == .excerpt)
    }

    @Test func pinnedCommitAndProposal() {
        let fence = NoteFence(info: "ts propose file=src/app.ts@1a2b3c4#L10-40")
        #expect(fence == NoteFence(language: "ts", path: "src/app.ts", commit: "1a2b3c4", lines: LineRange(start: 10, end: 40), propose: true))
        #expect(fence.mode == .propose)
        // `@` inside a path segment is not a commit.
        let scoped = NoteFence(info: "file=node_modules/@types/node/fs.d.ts#L3")
        #expect(scoped.path == "node_modules/@types/node/fs.d.ts")
        #expect(scoped.commit == nil)
    }

    @Test func backslashesInAnchorsAreLiteralExceptBeforeQuotes() {
        #expect(NoteFence(info: #"file=a.ts#L1 anchor="s.split(/\d+/)""#).anchor == #"s.split(/\d+/)"#)
        #expect(NoteFence(info: #"file=a.ts#L1 anchor="a \\ b""#).anchor == #"a \ b"#)
    }

    @Test func quotedAnchorKeepsSpacesAndEscapes() {
        let fence = NoteFence(info: #"ts file=a.ts#L3-5 anchor="let label = \"hi there\"" propose"#)
        #expect(fence.anchor == #"let label = "hi there""#)
        #expect(fence.propose)
        #expect(NoteFence(info: "file=a.ts#L3 anchor='func  go()'").anchor == "func  go()")
    }

    @Test func freeFences() {
        #expect(NoteFence(info: "ts").mode == .free)
        #expect(NoteFence(info: "ts").language == "ts")
        #expect(NoteFence(info: "").mode == .free)
        // `propose` without an anchor proposes nothing.
        #expect(NoteFence(info: "ts propose").mode == .free)
    }

    @Test func referencesInFreeText() {
        let text = "see src/app.ts:12 and ./lib/x.py:3-9, not https://example.com:443 or 10:30"
        let references = NoteReferences.find(in: text)
        #expect(references.map(\.path) == ["src/app.ts", "./lib/x.py"])
        #expect(references.map(\.lines) == [LineRange(start: 12, end: 12), LineRange(start: 3, end: 9)])
        #expect((text as NSString).substring(with: references[0].range) == "src/app.ts:12")
    }
}

@MainActor
struct NoteLinkTests {
    /// Each linked run of the rendered note: its text and where it goes.
    func links(_ markdown: String) -> [String: NoteLink] {
        let text = NoteRenderer(excerpts: [:]).render(NoteMarkdown.parse(markdown), placeholder: "")
        var found: [String: NoteLink] = [:]
        text.enumerateAttribute(.noteLink, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let encoded = value as? String else { return }
            found[(text.string as NSString).substring(with: range)] = NoteLink(encoded: encoded)
        }
        return found
    }

    @Test func pathLineReferencesLinkInTableCellsAndProse() {
        let found = links("""
        | # | frame | at |
        |---|---|---|
        | 1 | `Command.main` | src/click/_compat.py:12 |

        Fails in core.py:1587, see `tests/test_x.py:3-9`.
        """)
        // Markdown splits `_compat` into its own text run; the whole path still links.
        #expect(found["src/click/_compat.py:12"] == .code(path: "src/click/_compat.py", lines: LineRange(start: 12, end: 12)))
        #expect(found["core.py:1587"] == .code(path: "core.py", lines: LineRange(start: 1587, end: 1587)))
        #expect(found["tests/test_x.py:3-9"] == .code(path: "tests/test_x.py", lines: LineRange(start: 3, end: 9)))
        #expect(found.count == 3)
    }

    @Test func aMarkdownLinksTextKeepsItsDestination() {
        let found = links("[core.py:10](https://example.com/blame)")
        #expect(found == ["core.py:10": .web(URL(string: "https://example.com/blame")!)])
    }
}

struct NoteAnchorTests {
    let source = [
        "import x",          // 1
        "",                  // 2
        "func load() {",     // 3
        "    read()",        // 4
        "}",                 // 5
        "",                  // 6
        "func save() {",     // 7
        "    write()",       // 8
        "}",                 // 9
    ]

    @Test func lineRangeFollowsCapturedContentWhenLinesAreInsertedAbove() {
        let fence = NoteFence(path: "a.swift", lines: LineRange(start: 7, end: 9))
        let first = NoteAnchor.resolve(fence, in: source, captured: nil)
        #expect(first.range == LineRange(start: 7, end: 9))
        #expect(first.status == .exact)
        let captured = Array(source[6...8])

        let moved = ["// header", "// more"] + source
        let second = NoteAnchor.resolve(fence, in: moved, captured: captured)
        #expect(second.range == LineRange(start: 9, end: 11))
        #expect(second.status == .relocated(from: 7))
    }

    @Test func anchorAttributeRelocatesWithoutCapturedText() {
        let fence = NoteFence(path: "a.swift", lines: LineRange(start: 3, end: 5), anchor: "func save() {")
        let resolution = NoteAnchor.resolve(fence, in: source, captured: nil)
        #expect(resolution.range == LineRange(start: 7, end: 9))
        #expect(resolution.status == .relocated(from: 3))
    }

    @Test func proposalBodyRelocatesItsRangeWithoutCapturedText() {
        // After a restart nothing is captured; the proposal's own lines still find the range.
        let fence = NoteFence(path: "a.swift", lines: LineRange(start: 7, end: 9), propose: true)
        let proposed = ["func save() {", "    write()", "    flush()", "}"]
        let moved = ["// a", "// b", "// c"] + source
        #expect(NoteAnchor.resolve(fence, in: moved, captured: nil, body: proposed).range == LineRange(start: 10, end: 12))
        // Unmoved, the written range stands even though every `}` votes elsewhere too.
        #expect(NoteAnchor.resolve(fence, in: source, captured: nil, body: proposed).status == .exact)
        // An inserted line shifts the votes of every line below it; the top lines decide.
        let inserting = ["func save() {", "    validate()", "    write()", "}"]
        #expect(NoteAnchor.resolve(fence, in: moved, captured: nil, body: inserting).range == LineRange(start: 10, end: 12))
        // A body that matches nothing leaves the range as written.
        #expect(NoteAnchor.resolve(fence, in: moved, captured: nil, body: ["brand new"]).range == LineRange(start: 7, end: 9))
    }

    @Test func oldPositionHoldingOnlyTheFirstLineLosesToTheCapturedBlock() {
        // The block at L2-4 moved to the end; another `func a() {` now sits at L2.
        let captured = ["func a() {", "    two()", "}"]
        let file = ["x", "func a() {", "    other()", "}", "func a() {", "    two()", "}"]
        let fence = NoteFence(path: "a.swift", lines: LineRange(start: 2, end: 4))
        let resolution = NoteAnchor.resolve(fence, in: file, captured: captured)
        #expect(resolution.range == LineRange(start: 5, end: 7))
        #expect(resolution.status == .relocated(from: 2))
        // Unmoved, the written position wins its tie with an identical block further down.
        let twins = ["x", "func a() {", "    two()", "}", "func a() {", "    two()", "}"]
        #expect(NoteAnchor.resolve(fence, in: twins, captured: captured).status == .exact)
    }

    @Test func duplicateAnchorLinesPreferTheCapturedNeighbours() {
        let file = ["}", "func a() {", "    one()", "}", "func a() {", "    two()", "}"]
        let fence = NoteFence(path: "a.swift", lines: LineRange(start: 2, end: 4))
        let shifted = ["x"] + file
        // Both `func a() {` lines match the first line; only the second is followed by `two()`.
        let resolution = NoteAnchor.resolve(fence, in: shifted, captured: ["func a() {", "    two()", "}"])
        #expect(resolution.range == LineRange(start: 6, end: 8))
    }

    @Test func deletedRangeGoesStale() {
        let fence = NoteFence(path: "a.swift", lines: LineRange(start: 7, end: 9))
        let deleted = Array(source[0...5])
        let resolution = NoteAnchor.resolve(fence, in: deleted, captured: Array(source[6...8]))
        #expect(resolution.range == nil)
        guard case .stale = resolution.status else { Issue.record("expected stale, got \(resolution.status)"); return }
    }

    @Test func rangePastEndOfFileIsStale() {
        let resolution = NoteAnchor.resolve(NoteFence(path: "a.swift", lines: LineRange(start: 40, end: 50)), in: source, captured: nil)
        #expect(resolution.range == nil)
        #expect(resolution.status == .stale("lines 40-50 are past the end of the file (9 lines)"))
    }

    @Test func symbolsResolveToTheirBody() {
        let swift = [
            "struct Board {",
            "    var name = \"{\"",
            "    public func update(_ id: String) throws {",
            "        if id.isEmpty { return }",
            "    }",
            "}",
            "func update() {}",
        ]
        #expect(NoteAnchor.symbolRange("Board", in: swift) == LineRange(start: 1, end: 6))
        // The dotted form finds the member inside its container, not the top-level `update`.
        #expect(NoteAnchor.symbolRange("Board.update", in: swift) == LineRange(start: 3, end: 5))
        #expect(NoteAnchor.symbolRange("update", in: swift) == LineRange(start: 3, end: 5))
        #expect(NoteAnchor.symbolRange("missing", in: swift) == nil)

        let ts = [
            "const x = restoreSnapshot(1);",
            "export async function restoreSnapshot(id: string) {",
            "  const s = await load(id);",
            "  return s;",
            "}",
            "export const load = async (id: string) => {",
            "  return id;",
            "};",
        ]
        #expect(NoteAnchor.symbolRange("restoreSnapshot", in: ts) == LineRange(start: 2, end: 5))
        #expect(NoteAnchor.symbolRange("load", in: ts) == LineRange(start: 6, end: 8))

        let python = [
            "class Store:",
            "    def get(self, key):",
            "        value = self.data[key]",
            "",
            "        return value",
            "",
            "    def put(self, key):",
            "        pass",
        ]
        #expect(NoteAnchor.symbolRange("Store.get", in: python) == LineRange(start: 2, end: 5))
        #expect(NoteAnchor.symbolRange("Store", in: python) == LineRange(start: 1, end: 8))
    }

    @Test func symbolWinsOverLineRangeAndFallsBackToIt() {
        let fence = NoteFence(path: "a.swift", lines: LineRange(start: 3, end: 5), symbol: "save")
        #expect(NoteAnchor.resolve(fence, in: source, captured: nil).range == LineRange(start: 7, end: 9))
        let lost = NoteFence(path: "a.swift", lines: LineRange(start: 3, end: 5), symbol: "gone")
        #expect(NoteAnchor.resolve(lost, in: source, captured: nil).range == LineRange(start: 3, end: 5))
        let onlySymbol = NoteFence(path: "a.swift", symbol: "gone")
        #expect(NoteAnchor.resolve(onlySymbol, in: source, captured: nil).status == .stale("symbol gone not found"))
    }
}

struct NoteMarkdownTests {
    /// The anchor as the fence parser sees it after CommonMark has processed the info string.
    func parsedAnchor(_ markdown: String) -> String? {
        NoteMarkdown.anchoredFences(in: NoteMarkdown.parse(markdown)).first?.fence.anchor
    }

    @Test func writtenAnchorsSurviveCommonMarkAndReadBackVerbatim() throws {
        let lines = [
            #"let label = "hi" & 'there'"#,
            #"const re = /\d+\s*"x"/"#,
            #"say("a \\ b")"#,
            "plain line",
        ]
        for line in lines {
            let markdown = "# t\n\n```ts file=a.ts#L3-5\n```\n"
            let anchored = try #require(NoteMarkdown.anchoring(markdown, fenceLines: [3], anchor: line))
            #expect(parsedAnchor(anchored) == line, "\(anchored)")
        }
    }

    @Test func anchorsFenceLinesInsideContainersAndRefusesBackticks() throws {
        let markdown = "- item\n\n  ```ts file=a.ts#L1-2\n  ```\n\n> ```ts file=a.ts#L1-2 propose\n> x\n> ```\n"
        let fences = NoteMarkdown.anchoredFences(in: NoteMarkdown.parse(markdown))
        #expect(fences.map(\.lines) == [[3], [6]])
        var text = markdown
        for fence in fences { text = try #require(NoteMarkdown.anchoring(text, fenceLines: fence.lines, anchor: "func go() {")) }
        #expect(NoteMarkdown.anchoredFences(in: NoteMarkdown.parse(text)).map(\.fence.anchor) == ["func go() {", "func go() {"])
        #expect(NoteMarkdown.anchoredFences(in: NoteMarkdown.parse(text))[1].body == ["x"], "the fence body is untouched")
        // A backtick fence's info string can't hold a backtick; a tilde fence can.
        #expect(NoteMarkdown.anchoring("```ts file=a.ts#L1\n```", fenceLines: [1], anchor: "let s = `x`") == nil)
        let tilde = try #require(NoteMarkdown.anchoring("~~~ts file=a.ts#L1\n~~~", fenceLines: [1], anchor: "let s = `x`"))
        #expect(parsedAnchor(tilde) == "let s = `x`")
        #expect(NoteMarkdown.anchoring("plain\n```ts file=a.ts#L1\n```", fenceLines: [1], anchor: "x") == nil, "line 1 is not a fence")
    }
}

@MainActor
struct NoteEditSessionTests {
    let board = Board(id: "brd_test", root: URL(fileURLWithPath: NSTemporaryDirectory()))

    func markdown(_ id: ObjectID) -> String? { board.objects[id]?.props["markdown"]?.string }

    @Test func implicitCommitsNeverOverwriteSomeoneElsesChange() throws {
        let note = board.create(type: .note, props: .object(["markdown": .string("base")]))
        let session = NoteEditSession(note)
        board.onEvent = { event in if case .objectUpdated(let object) = event { session.observe(object) } }
        try board.update(note.id, props: .object(["markdown": .string("theirs")]), caller: "obj_agent")
        #expect(session.conflicted)

        // Clicking away, then focus moving to a terminal: two implicit commits.
        #expect(try session.commit("mine", confirmed: false, on: board) == .conflict)
        #expect(try session.commit("mine", confirmed: false, on: board) == .conflict)
        #expect(markdown(note.id) == "theirs")

        #expect(try session.commit("mine", confirmed: true, on: board) == .saved)
        #expect(markdown(note.id) == "mine")
    }

    @Test func aConflictFoundAtCommitIsShownBeforeItCanBeOverwritten() throws {
        let note = board.create(type: .note, props: .object(["markdown": .string("base")]))
        let session = NoteEditSession(note)
        // No observer: the change is only discovered by the commit itself.
        try board.update(note.id, props: .object(["markdown": .string("theirs")]), caller: "obj_agent")
        #expect(try session.commit("mine", confirmed: true, on: board) == .conflict)
        #expect(markdown(note.id) == "theirs")
        #expect(try session.commit("mine", confirmed: true, on: board) == .saved)
        #expect(markdown(note.id) == "mine")
    }

    @Test func ownSavesAndNonMarkdownChangesAreNotConflicts() throws {
        let note = board.create(type: .note, props: .object(["markdown": .string("base")]))
        let session = NoteEditSession(note)
        board.onEvent = { event in if case .objectUpdated(let object) = event { session.observe(object) } }
        try board.update(note.id, frame: Frame(x: 50, y: 50, w: 280, h: 240))
        #expect(try session.commit("mine", confirmed: false, on: board) == .saved)
        #expect(!session.conflicted)
        #expect(try session.commit("mine", confirmed: false, on: board) == .unchanged)
    }

    @Test func keepingTheirsLeavesYoursOneUndoAway() throws {
        let note = board.create(type: .note, props: .object(["markdown": .string("base")]))
        let session = NoteEditSession(note)
        board.onEvent = { event in if case .objectUpdated(let object) = event { session.observe(object) } }
        try board.update(note.id, props: .object(["markdown": .string("theirs")]), caller: "obj_agent")
        #expect(try session.commit("base, mine", confirmed: false, on: board) == .conflict)

        #expect(session.keepTheirs(discarding: "base, mine", on: board))
        #expect(markdown(note.id) == "theirs")
        #expect(board.undo())
        #expect(markdown(note.id) == "base, mine")
        #expect(board.redo())
        #expect(markdown(note.id) == "theirs")
        // Under it, the agent's own change is still a step of its own.
        #expect(board.undo() && board.undo())
        #expect(markdown(note.id) == "base")
    }

    @Test func keepingTheirsOverAnUnchangedEditRecordsNothing() throws {
        let note = board.create(type: .note, props: .object(["markdown": .string("base")]))
        let session = NoteEditSession(note)
        try board.update(note.id, props: .object(["markdown": .string("theirs")]), caller: "obj_agent")
        let steps = board.history.undoSteps.count
        #expect(!session.keepTheirs(discarding: "base", on: board))
        #expect(!session.keepTheirs(discarding: "theirs", on: board))
        #expect(board.history.undoSteps.count == steps)
    }
}

struct NoteDiffTests {
    @Test func proposalDiffAgainstTheRealRange() {
        let real = ["func load() {", "    read()", "    parse()", "}"]
        let proposed = ["func load() async {", "    read()", "    try validate()", "    parse()", "}"]
        let diff = NoteDiff.lines(real, proposed)
        #expect(diff == [
            .removed(old: 0, "func load() {"),
            .added(new: 0, "func load() async {"),
            .same(old: 1, new: 1, "    read()"),
            .added(new: 2, "    try validate()"),
            .same(old: 2, new: 3, "    parse()"),
            .same(old: 3, new: 4, "}"),
        ])
    }

    @Test func removalsPrecedeAdditionsInAChangedRun() {
        let diff = NoteDiff.lines(["a", "b", "c", "d"], ["a", "x", "y", "d"])
        #expect(diff == [
            .same(old: 0, new: 0, "a"),
            .removed(old: 1, "b"), .removed(old: 2, "c"),
            .added(new: 1, "x"), .added(new: 2, "y"),
            .same(old: 3, new: 3, "d"),
        ])
    }

    @Test func pastTheEditBudgetTheMiddleIsReplacedWholesale() {
        let old = ["keep", "a", "b", "c", "end"]
        let new = ["keep", "x", "b", "y", "end"]
        #expect(NoteDiff.lines(old, new, maxEdits: 1) == [
            .same(old: 0, new: 0, "keep"),
            .removed(old: 1, "a"), .removed(old: 2, "b"), .removed(old: 3, "c"),
            .added(new: 1, "x"), .added(new: 2, "b"), .added(new: 3, "y"),
            .same(old: 4, new: 4, "end"),
        ])
        #expect(NoteDiff.keptCount(old, new) == 3)
    }

    @Test func wholeFileRewriteStaysBounded() {
        let old = (0..<20_000).map { "old \($0)" }
        let new = (0..<20_000).map { "new \($0)" }
        let clock = ContinuousClock()
        let started = clock.now
        let diff = NoteDiff.lines(old, new)
        #expect(diff.count == 40_000)
        #expect(clock.now - started < .seconds(5))
    }

    @Test func emptySides() {
        #expect(NoteDiff.lines([], ["a"]) == [.added(new: 0, "a")])
        #expect(NoteDiff.lines(["a"], []) == [.removed(old: 0, "a")])
        #expect(NoteDiff.lines(["a"], ["a"]) == [.same(old: 0, new: 0, "a")])
    }

    @Test func minimalEditScriptOnInterleavedChanges() {
        let old = ["a", "b", "c", "a", "b", "b", "a"]
        let new = ["c", "b", "a", "b", "a", "c"]
        let diff = NoteDiff.lines(old, new)
        let edits = diff.filter { if case .same = $0 { false } else { true } }.count
        #expect(edits == 5, "Myers' classic example has a 5-edit shortest script")
        // Replaying the script reproduces both sides.
        #expect(diff.compactMap { if case .added(_, let s) = $0 { s } else if case .same(_, _, let s) = $0 { s } else { nil } } == new)
        #expect(diff.compactMap { if case .removed(_, let s) = $0 { s } else if case .same(_, _, let s) = $0 { s } else { nil } } == old)
    }
}

struct NoteSourceTests {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-note-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    }

    init(root: URL) {
        self.root = root
    }

    func write(_ path: String, _ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    /// git on a GCD thread: blocking inside a test task would park a cooperative-pool thread.
    @discardableResult
    func git(_ args: String...) async throws -> String {
        let root = root
        let (status, output) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, String), Error>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
                process.currentDirectoryURL = root
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    return continuation.resume(throwing: error)
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
        #expect(status == 0, "git \(args.joined(separator: " "))")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func excerptFollowsEditsOnDisk() async throws {
        try write("src/a.ts", ["one", "two", "three", "four"])
        let fence = NoteFence(info: "ts file=src/a.ts#L3-4")
        let first = await NoteSource.excerpt(for: fence, root: root, captured: nil)
        #expect(first.lines == ["three", "four"])
        #expect(first.status == .exact)

        try write("src/a.ts", ["zero", "one", "two", "three", "four"])
        let moved = await NoteSource.excerpt(for: fence, root: root, captured: first.lines)
        #expect(moved.range == LineRange(start: 4, end: 5))
        #expect(moved.lines == ["three", "four"])

        try write("src/a.ts", ["zero", "one", "two"])
        let lost = await NoteSource.excerpt(for: fence, root: root, captured: first.lines)
        #expect(lost.isStale)
        #expect(lost.lines == ["three", "four"], "a stale excerpt keeps showing what it last showed")
    }

    @Test func missingFileIsStale() async {
        let excerpt = await NoteSource.excerpt(for: NoteFence(info: "file=nope.ts#L1"), root: root, captured: nil)
        #expect(excerpt.status == .stale("no file nope.ts"))
    }

    @Test func proposalDiffAndInsertionLinesComeWithTheExcerpt() async throws {
        try write("src/a.ts", ["one", "two", "three", "four", "five"])
        let appended = await NoteSource.excerpt(for: NoteFence(info: "ts file=src/a.ts#L2-3 propose"), root: root, captured: nil, body: ["two", "three", "inserted"])
        #expect(appended.diff == [.same(old: 0, new: 0, "two"), .same(old: 1, new: 1, "three"), .added(new: 2, "inserted")])
        // Appended past the range: inserted before L4, not a second mention of L3.
        #expect(appended.proposalLines == [2, 3, 4])
        let atEnd = await NoteSource.excerpt(for: NoteFence(info: "ts file=src/a.ts#L4-5 propose"), root: root, captured: nil, body: ["four", "five", "six"])
        #expect(atEnd.proposalLines == [4, 5, 5], "appended at end of file it follows the last line")
    }

    @Test func optionLikeRevisionsAreRejected() async throws {
        try await git("init", "-q")
        try write("src/a.ts", ["one"])
        try await git("add", ".")
        try await git("commit", "-q", "-m", "subject line")
        let excerpt = await NoteSource.excerpt(for: NoteFence(info: "ts file=src/a.ts#L1 commit=--format=%s"), root: root, captured: nil)
        #expect(excerpt.isStale)
        #expect(excerpt.lines.isEmpty, "never git's option output as file text")
    }

    @Test func aHugeGitDiagnosticDoesNotWedgeTheRunner() async throws {
        try await git("init", "-q")
        try write("src/a.ts", ["one"])
        try await git("add", ".")
        try await git("commit", "-q", "-m", "one")
        // git's fatal message repeats the revision: far more than a pipe buffer on stderr.
        let revision = String(repeating: "a", count: 200_000)
        let failed = await NoteSource.excerpt(for: NoteFence(info: "ts file=src/a.ts@\(revision)#L1"), root: root, captured: nil)
        #expect(failed.isStale)
        let pinned = await NoteSource.excerpt(for: NoteFence(info: "ts file=src/a.ts@HEAD#L1"), root: root, captured: nil)
        #expect(pinned.lines == ["one"])
    }

    @Test func gitRunnerCancelsQueuedAndRunningRequests() async throws {
        try await git("init", "-q")
        let runner = GitRunner(limit: 1)
        let root = root
        // A git that runs for a while, holding the only slot.
        let slow = ["-c", "alias.slow=!sleep 1", "slow"]
        let holder = Task { try await runner.run(slow, in: root) }
        try await Task.sleep(for: .milliseconds(100))
        let queued = Task { try await runner.run(["rev-parse", "--git-dir"], in: root) }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let started = clock.now
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(clock.now - started < .milliseconds(500), "a queued request leaves without waiting for the slot")

        holder.cancel()
        await #expect(throws: CancellationError.self) { try await holder.value }
        // Both slots were given back exactly once: the runner still works, one at a time.
        let data = try await runner.run(["rev-parse", "--git-dir"], in: root)
        #expect(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == ".git")
        await #expect(throws: GitError.timedOut) { try await runner.run(slow, in: root, timeout: 0.2) }
    }

    @Test func cancelledRequestsGiveBackTheirGitPermits() async throws {
        try await git("init", "-q")
        try write("src/a.ts", ["one"])
        try await git("add", ".")
        try await git("commit", "-q", "-m", "one")
        let fence = NoteFence(info: "ts file=src/a.ts@HEAD#L1")
        let root = root
        let abandoned = (0..<12).map { _ in Task { await NoteSource.excerpt(for: fence, root: root, captured: nil) } }
        abandoned.forEach { $0.cancel() }
        for task in abandoned { _ = await task.value }
        for _ in 0..<3 {
            #expect(await NoteSource.excerpt(for: fence, root: root, captured: nil).lines == ["one"])
        }
    }

    @Test func pinnedCommitReadsThroughGitShow() async throws {
        try await git("init", "-q")
        try write("src/a.ts", ["old 1", "old 2", "old 3"])
        try await git("add", ".")
        try await git("commit", "-q", "-m", "one")
        let sha = try await git("rev-parse", "--short", "HEAD")
        try write("src/a.ts", ["new 1", "new 2"])
        try await git("commit", "-q", "-am", "two")

        let pinned = await NoteSource.excerpt(for: NoteFence(info: "ts file=src/a.ts@\(sha)#L2-3"), root: root, captured: nil)
        #expect(pinned.lines == ["old 2", "old 3"])
        #expect(pinned.status == .exact)
        let live = await NoteSource.excerpt(for: NoteFence(info: "ts file=src/a.ts#L1-2"), root: root, captured: nil)
        #expect(live.lines == ["new 1", "new 2"])
        let bogus = await NoteSource.excerpt(for: NoteFence(info: "ts file=src/a.ts@0000000#L1"), root: root, captured: nil)
        #expect(bogus.status == .stale("unknown commit 0000000"))
    }

    @Test func workspaceSymbolSearchFindsTheDeclaringFile() async throws {
        try await git("init", "-q")
        try write("src/use.ts", ["import { restoreSnapshot } from './snap'", "restoreSnapshot(1)"])
        try write("src/snap.ts", ["// snapshots", "export function restoreSnapshot(id: number) {", "  return id", "}"])
        try await git("add", ".")
        let excerpt = await NoteSource.excerpt(for: NoteFence(info: "ts symbol=restoreSnapshot"), root: root, captured: nil)
        #expect(excerpt.path == "src/snap.ts")
        #expect(excerpt.range == LineRange(start: 2, end: 4))
        let missing = await NoteSource.excerpt(for: NoteFence(info: "ts symbol=nothingHere"), root: root, captured: nil)
        #expect(missing.isStale)
    }
}

@MainActor
struct PinnedMentionTests {
    @Test func pinnedExcerptRowsMentionTheirCommit() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = NoteSourceTests(root: root)
        try await fixture.git("init", "-q")
        try fixture.write("a.ts", ["then 1", "then 2"])
        try await fixture.git("add", ".")
        try await fixture.git("commit", "-q", "-m", "one")
        let sha = try await fixture.git("rev-parse", "HEAD")
        try fixture.write("a.ts", ["now 1", "now 2"])

        let fence = NoteFence(info: "ts file=a.ts@\(sha)#L2")
        let excerpt = await NoteSource.excerpt(for: fence, root: root, captured: nil)
        #expect(excerpt.lines == ["then 2"])
        let board = Board(id: "brd_test", root: root)
        let note = board.create(type: .note, props: .object(["markdown": .string("```ts file=a.ts@\(sha)#L2\n```")]))
        try board.stage(.code(object: note.id, path: excerpt.path, lines: LineRange(start: 2, end: 2), symbol: fence.symbol, commit: fence.commit))
        let context = await board.drain().context
        #expect(context.contains("at \(sha.prefix(7))"))
        #expect(context.contains("then 2"))
        #expect(!context.contains("now 2"), "a pinned mention never drains today's file")
    }
}

struct NoteItemTests {
    static let audit = """
    # Audit log: trade-up-bot

    Intro paragraph that
    wraps onto two lines.

    ## Leads

    1. Session secret fallback
    2. Unescaped og:image
    3. JSON-LD not escaped
    4. Rate limit keyed on IP
       - behind a proxy: all one key
       - see server/index.ts:117
    5. CSP allows unsafe-inline

    #### Rate limits

    > Quoted finding
    > continues

    | Lead | Severity |
    | --- | --- |
    | rlKey | Low |
    | seo | Med |

    ```ts
    const x = 1
    ```

    ## Fixed

    Nothing yet.
    """

    func item(_ line: Int, in markdown: String = audit) throws -> NoteItem {
        try #require(NoteItem.at(line: line, in: markdown))
    }

    @Test func paragraphIsItsLinesUnderItsHeading() throws {
        let paragraph = try item(4)
        #expect(paragraph.kind == .paragraph)
        #expect(paragraph.lines == LineRange(start: 3, end: 4))
        #expect(paragraph.headings == ["Audit log: trade-up-bot"])
        #expect(paragraph.text == "Intro paragraph that\nwraps onto two lines.")
    }

    @Test func listItemCarriesItsNestedItems() throws {
        let lead = try item(11)
        #expect(lead.kind == .item)
        #expect(lead.lines == LineRange(start: 11, end: 13))
        #expect(lead.headings == ["Audit log: trade-up-bot", "Leads"])
        #expect(lead.text == "4. Rate limit keyed on IP\n   - behind a proxy: all one key\n   - see server/index.ts:117")
        #expect(lead.summary == "4. Rate limit keyed on IP")

        let nested = try item(12)
        #expect(nested.lines == LineRange(start: 12, end: 12))
        #expect(nested.text == "- behind a proxy: all one key", "indentation of the nesting is dropped")
        #expect(nested.summary == "behind a proxy: all one key")
    }

    @Test func headingIsItsSectionUpToTheNextOfTheSameLevel() throws {
        let leads = try item(6)
        #expect(leads.kind == .heading)
        #expect(leads.lines == LineRange(start: 6, end: 28), "the deeper #### section is part of it; ## Fixed ends it")
        #expect(leads.headings == ["Audit log: trade-up-bot"])
        #expect(leads.summary == "Leads")
        #expect(leads.text.hasPrefix("## Leads\n\n1. Session secret fallback"))
    }

    @Test func headingPathSkipsMissingLevels() throws {
        let section = try item(16)
        #expect(section.lines == LineRange(start: 16, end: 28))
        #expect(section.headings == ["Audit log: trade-up-bot", "Leads"])
        #expect(try item(19).headings == ["Audit log: trade-up-bot", "Leads", "Rate limits"])
        #expect(try item(32).headings == ["Audit log: trade-up-bot", "Fixed"], "a later ## leaves the #### section")
    }

    @Test func quoteRowAndFence() throws {
        let quote = try item(19)
        #expect(quote.kind == .quote)
        #expect(quote.lines == LineRange(start: 18, end: 19))

        let row = try item(23)
        #expect(row.kind == .row)
        #expect(row.text == "| rlKey | Low |")
        #expect(row.summary == "rlKey · Low")
        #expect(try item(22).lines == LineRange(start: 21, end: 21), "the delimiter row stands for the header")

        let fence = try item(27)
        #expect(fence.kind == .code)
        #expect(fence.lines == LineRange(start: 26, end: 28))
        #expect(fence.summary == "const x = 1")
    }

    @Test func blankLinesAndRulesAreNoBlock() {
        #expect(NoteItem.at(line: 2, in: Self.audit) == nil)
        #expect(NoteItem.at(line: 99, in: Self.audit) == nil)
        #expect(NoteItem.at(line: 2, in: "a\n\n---\n\nb") == nil)
        #expect(NoteItem.at(line: 3, in: "a\n\n---\n\nb") == nil)
    }

    @Test func longBlocksAreCutToWholeLines() throws {
        let markdown = "# Big\n\n" + (1...60).map { "- item \($0)" }.joined(separator: "\n")
        let section = try item(1, in: markdown)
        #expect(section.lines == LineRange(start: 1, end: 62))
        #expect(NoteSource.lines(of: section.text).count == NoteItem.maxLines)
        #expect(section.omittedLines == 62 - NoteItem.maxLines)

        let wide = String(repeating: "word ", count: 1000)
        let paragraph = try item(1, in: wide)
        #expect(paragraph.text.count == NoteItem.maxCharacters)
        #expect(paragraph.text.hasSuffix("…"))
    }

    @Test func refindsTheBlockAfterEdits() throws {
        let lead = try item(11)
        let moved = "Preface\n\n" + Self.audit
        let found = try #require(NoteItem.find(lead.text, near: lead.lines.start, in: moved))
        #expect(found.unchanged)
        #expect(found.item.lines == LineRange(start: 13, end: 15))

        let grown = Self.audit.replacingOccurrences(of: "   - see server/index.ts:117", with: "   - see server/index.ts:117\n   - fixed in 1a2b3c4")
        let changed = try #require(NoteItem.find(lead.text, near: lead.lines.start, in: grown))
        #expect(!changed.unchanged)
        #expect(changed.item.text.hasSuffix("- fixed in 1a2b3c4"))

        let reworded = Self.audit.replacingOccurrences(of: "4. Rate limit keyed on IP", with: "4. Rate limit keyed on the client IP")
        #expect(NoteItem.find(lead.text, near: lead.lines.start, in: reworded) == nil)

        // Twice in the note: the one nearest where it was.
        let twice = Self.audit + "\n\n4. Rate limit keyed on IP\n   - behind a proxy: all one key\n   - see server/index.ts:117\n"
        #expect(NoteItem.find(lead.text, near: lead.lines.start, in: twice)?.item.lines.start == 11)
    }
}

@MainActor
struct NoteMentionTests {
    let board = Board(id: "brd_test", root: URL(fileURLWithPath: NSTemporaryDirectory()))

    func stageLead() throws -> (note: CanvasObject, mention: Mention) {
        let note = board.create(type: .note, props: .object(["markdown": .string(NoteItemTests.audit)]))
        let item = try #require(NoteItem.at(line: 11, in: NoteItemTests.audit))
        return (note, try board.stage(.note(object: note.id, item: item)))
    }

    @Test func chipNamesTheNoteAndTheItem() throws {
        let (_, mention) = try stageLead()
        #expect(mention.label == "note Audit log: tr… › 4. Rate limit keyed on …", "short enough for the chip to show whole")
    }

    @Test func contextGivesHeadingPathAndTheItemsText() async throws {
        let (note, _) = try stageLead()
        let context = await board.drain(peek: true).context
        #expect(context.contains("[1] note \(note.id) \"Audit log: trade-up-bot\" · list item, markdown lines 11-13 · in Audit log: trade-up-bot › Leads\n"))
        #expect(context.contains("\n    4. Rate limit keyed on IP\n       - behind a proxy: all one key\n       - see server/index.ts:117\n"))
        #expect(!context.contains("CSP allows"), "only the item")
    }

    @Test func editedNoteRefindsTheItemOrSaysItChanged() async throws {
        let (note, _) = try stageLead()
        try board.update(note.id, props: .object(["markdown": .string("Preface\n\n" + NoteItemTests.audit)]))
        let moved = await board.drain(peek: true).context
        #expect(moved.contains("list item, markdown lines 13-15 · in Audit log: trade-up-bot › Leads (edited)"))
        #expect(!moved.contains("changed since"))

        try board.update(note.id, props: .object(["markdown": .string(NoteItemTests.audit.replacingOccurrences(of: "   - see server/index.ts:117", with: "   - fixed"))]))
        let grown = await board.drain(peek: true).context
        #expect(grown.contains("(changed since it was mentioned; as it reads now:)\n    4. Rate limit keyed on IP\n       - behind a proxy: all one key\n       - fixed"))

        try board.update(note.id, props: .object(["markdown": .string("# Audit log: trade-up-bot\n\nAll fixed.")]))
        let gone = await board.drain(peek: true).context
        #expect(gone.contains("(no longer in the note; as it read when mentioned:)\n    4. Rate limit keyed on IP"))
    }

    @Test func noteMentionsKeepTheirBlockThroughTheBoardFile() throws {
        let (_, mention) = try stageLead()
        let json = try JSONValue.encode(mention.target)
        #expect(json["kind"]?.string == "note")
        #expect(json["block"]?.string == "item")
        #expect(json["headings"] == .array([.string("Audit log: trade-up-bot"), .string("Leads")]))
        #expect(try json.decode(MentionTarget.self) == mention.target)
    }

    @Test func wholeNoteMentionCarriesTheWholeNoteUpToACap() async throws {
        let long = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let short = board.create(type: .note, props: .object(["markdown": .string(NoteItemTests.audit)]))
        let big = board.create(type: .note, props: .object(["markdown": .string(long)]))
        try board.stage(.object(short.id))
        try board.stage(.object(big.id))
        let context = await board.drain().context
        #expect(context.contains("    Nothing yet."), "a note of 32 lines arrives whole")
        #expect(context.contains("    line 80\n    … 20 more lines (canvas get \(big.id))"))
        #expect(!context.contains("line 81"))
    }
}
