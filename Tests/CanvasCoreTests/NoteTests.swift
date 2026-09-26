import Foundation
import Testing
import CanvasCore

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

    func write(_ path: String, _ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
        process.currentDirectoryURL = root
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(args.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
        #expect(excerpt.status == .stale("cannot read nope.ts"))
    }

    @Test func pinnedCommitReadsThroughGitShow() async throws {
        try git("init", "-q")
        try write("src/a.ts", ["old 1", "old 2", "old 3"])
        try git("add", ".")
        try git("commit", "-q", "-m", "one")
        let sha = try git("rev-parse", "--short", "HEAD")
        try write("src/a.ts", ["new 1", "new 2"])
        try git("commit", "-q", "-am", "two")

        let pinned = await NoteSource.excerpt(for: NoteFence(info: "ts file=src/a.ts@\(sha)#L2-3"), root: root, captured: nil)
        #expect(pinned.lines == ["old 2", "old 3"])
        #expect(pinned.status == .exact)
        let live = await NoteSource.excerpt(for: NoteFence(info: "ts file=src/a.ts#L1-2"), root: root, captured: nil)
        #expect(live.lines == ["new 1", "new 2"])
        let bogus = await NoteSource.excerpt(for: NoteFence(info: "ts file=src/a.ts@0000000#L1"), root: root, captured: nil)
        #expect(bogus.status == .stale("cannot read src/a.ts at 0000000"))
    }

    @Test func workspaceSymbolSearchFindsTheDeclaringFile() async throws {
        try git("init", "-q")
        try write("src/use.ts", ["import { restoreSnapshot } from './snap'", "restoreSnapshot(1)"])
        try write("src/snap.ts", ["// snapshots", "export function restoreSnapshot(id: number) {", "  return id", "}"])
        try git("add", ".")
        let excerpt = await NoteSource.excerpt(for: NoteFence(info: "ts symbol=restoreSnapshot"), root: root, captured: nil)
        #expect(excerpt.path == "src/snap.ts")
        #expect(excerpt.range == LineRange(start: 2, end: 4))
        let missing = await NoteSource.excerpt(for: NoteFence(info: "ts symbol=nothingHere"), root: root, captured: nil)
        #expect(missing.isStale)
    }
}
