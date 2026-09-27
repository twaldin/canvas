import Foundation
import Testing
@testable import CanvasCore

/// A repository with uncommitted work across several files, as an agent leaves it: two
/// separate edits in one file, an untracked file, a deleted file, and one hunk already staged.
private func workRepo() async throws -> TempRepo {
    let repo = try await TempRepo()
    try await repo.write("app.txt", numbered(1...30))
    try await repo.write("gone.txt", numbered(1...3))
    try await repo.write("staged.txt", numbered(1...5))
    try await repo.commit("base")
    var lines = (1...30).map { "line \($0)" }
    lines[2] = "line 3 changed"
    lines.insert("inserted after 20", at: 20)
    try await repo.write("app.txt", lines.joined(separator: "\n") + "\n")
    try await repo.write("new.txt", "fresh\nfile\n")
    let gone = repo.url("gone.txt")
    try await offPool { Result { try FileManager.default.removeItem(at: gone) } }.get()
    try await repo.write("staged.txt", numbered(1...6))
    try await repo.git("add", "staged.txt")
    return repo
}

/// `git diff` hunk headers without git's function context (`@@ -1,6 +1,6 @@ line 3` → `@@ -1,6 +1,6 @@`).
private func gitHeaders(_ repo: TempRepo, _ args: String...) async throws -> [String] {
    let output = try await TempRepo.run(["diff", "--no-color", "-U3"] + args, in: repo.root)
    return output.split(separator: "\n").filter { $0.hasPrefix("@@") }.map { line in
        let parts = line.components(separatedBy: " @@")
        return parts[0] + " @@"
    }
}

private func read(_ url: URL) async -> String? {
    await offPool { try? String(contentsOf: url, encoding: .utf8) }
}

@MainActor
struct ChangeSetTests {
    @Test func listsEveryChangedFileWithGitsHunks() async throws {
        let repo = try await workRepo()
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object([:])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        #expect(set.notice == nil)
        #expect(set.baseLabel == "HEAD")
        #expect(set.files.map(\.path) == ["app.txt", "gone.txt", "new.txt", "staged.txt"])
        #expect(set.files.map(\.status) == [.modified, .deleted, .added, .modified])
        let app = set.files[0]
        #expect(app.added == 2 && app.removed == 1)
        #expect(app.hunks.map(\.header) == (try await gitHeaders(repo, "HEAD", "--", "app.txt")))
        // Hunk rows: 3 lines of context around each change, removed before added.
        #expect(app.hunks[0].lines.map(\.kind) == [.context, .context, .removed, .added, .context, .context, .context])
        #expect(app.hunks[0].lines[2] == ChangeLine(kind: .removed, old: 3, new: nil))
        #expect(app.hunks[0].lines[3] == ChangeLine(kind: .added, old: nil, new: 3))
        #expect(set.files[1].removed == 3 && set.files[1].hunks.map(\.header) == ["@@ -1,3 +0,0 @@"])
        #expect(set.files[2].added == 2 && !set.files[2].tracked && set.files[2].hunks.map(\.header) == ["@@ -0,0 +1,2 @@"])
        // What the index holds: the staged file's hunk, nothing else.
        #expect(set.files.flatMap { $0.hunks.map(\.status) } == [.unstaged, .unstaged, .unstaged, .unstaged, .staged])
        #expect(set.summary.hasPrefix("4 files · +5 −4 · HEAD "))
    }

    @Test func pathsLimitTheListAndNeverLeaveTheRepository() async throws {
        let repo = try await workRepo()
        let engine = GitDiffEngine(watchesRepositories: false)
        let limited = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["paths": ["new.txt", "app.txt"]])), highlight: false, engine: engine)
        #expect(limited.files.map(\.path) == ["app.txt", "new.txt"])
        let outside = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["paths": ["../elsewhere"]])), highlight: false, engine: engine)
        #expect(outside.files.isEmpty)
        #expect(outside.notice?.contains("outside the repository") == true)
    }

    @Test func aBaseOlderThanHeadMarksCommittedHunks() async throws {
        let repo = try await TempRepo()
        try await repo.write("a.txt", numbered(1...20))
        let first = try await repo.commit("one")
        try await repo.write("a.txt", numbered(1...20).replacingOccurrences(of: "line 2\n", with: "line two\n"))
        try await repo.commit("two")
        try await repo.write("a.txt", numbered(1...20).replacingOccurrences(of: "line 2\n", with: "line two\n").replacingOccurrences(of: "line 18\n", with: "line eighteen\n"))
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["base": .string(first)])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        #expect(set.files.first?.hunks.map(\.status) == [.committed, .unstaged])
    }
}

@MainActor
struct ReviewPatchTests {
    @Test func patchTextIsWhatGitDiffPrints() async throws {
        // Changes 7 unchanged lines apart are two hunks (6 apart would share their context).
        let old = SideText("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n")
        let new = SideText("a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nnew")
        let text = ReviewPatch.text(path: "dir/f.txt", old: old, new: new, mappings: [
            LineRangeMapping(original: 2..<3, modified: 2..<3),
            LineRangeMapping(original: 11..<11, modified: 11..<12),
        ])
        #expect(text == """
        diff --git a/dir/f.txt b/dir/f.txt
        --- a/dir/f.txt
        +++ b/dir/f.txt
        @@ -1,5 +1,5 @@
         a
        -b
        +B
         c
         d
         e
        @@ -8,3 +8,4 @@
         h
         i
         j
        +new
        \\ No newline at end of file

        """)
        let created = ReviewPatch.text(path: "n.txt", old: nil, new: SideText("x\r\n"), newMode: "100755", mappings: [LineRangeMapping(original: 1..<1, modified: 1..<2)])
        #expect(created == "diff --git a/n.txt b/n.txt\nnew file mode 100755\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+x\r\n")
    }

    @Test func revertThenUndoPutsTheHunkBackExactly() async throws {
        let repo = try await workRepo()
        let engine = GitDiffEngine(watchesRepositories: false)
        let git = ReviewGit()
        let board = Board(id: "brd_t", root: repo.root)
        let tile = board.create(type: .changes, props: .object([:]))
        let before = try #require(await read(repo.url("app.txt")))
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(tile.props), highlight: false, engine: engine)
        let app = set.files[0]

        let patch = try ReviewPatch.revert([app.hunks[0]], of: app, in: try #require(set.repository))
        try await git.apply(patch)
        try board.recordReview(tile: tile.id, entry: .object(["action": "revert", "path": "app.txt", "header": .string(app.hunks[0].header)]), patch: patch, git: git)
        let reverted = try #require(await read(repo.url("app.txt")))
        #expect(reverted.contains("line 3\n") && !reverted.contains("line 3 changed"))
        #expect(reverted.contains("inserted after 20"))
        #expect(try await gitHeaders(repo, "--", "app.txt").count == 1)
        #expect(board.objects[tile.id]?.props["reviewed"]?.array?.count == 1)

        #expect(board.undo())
        await git.settled()
        #expect(await read(repo.url("app.txt")) == before)
        #expect(board.objects[tile.id]?.props["reviewed"] == nil)

        #expect(board.redo())
        await git.settled()
        #expect(await read(repo.url("app.txt")) == reverted)
    }

    @Test func stageThenUndoLeavesTheIndexAsItWas() async throws {
        let repo = try await workRepo()
        let engine = GitDiffEngine(watchesRepositories: false)
        let git = ReviewGit()
        let board = Board(id: "brd_t", root: repo.root)
        let tile = board.create(type: .changes, props: .object([:]))
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(tile.props), highlight: false, engine: engine)
        let top = try #require(set.repository)
        let cachedBefore = try await TempRepo.run(["diff", "--cached"], in: repo.root)

        // One hunk of a modified file: only it reaches the index.
        let app = set.files[0]
        let patch = try await ReviewPatch.stage([app.hunks[1]], of: app, in: top)
        try await git.apply(patch)
        try board.recordReview(tile: tile.id, entry: .object(["action": "stage", "path": "app.txt"]), patch: patch, git: git)
        #expect(try await gitHeaders(repo, "--cached", "--", "app.txt") == [app.hunks[1].header])
        #expect(try await gitHeaders(repo, "--", "app.txt") == [app.hunks[0].header])
        let reloaded = await ChangeSet.load(root: repo.root, spec: ChangesSpec(tile.props), highlight: false, engine: engine)
        #expect(reloaded.files[0].hunks.map(\.status) == [.unstaged, .staged])
        // Staging it again is refused.
        await #expect(throws: ChangesFailure.self) { try await ReviewPatch.stage([reloaded.files[0].hunks[1]], of: reloaded.files[0], in: top) }

        #expect(board.undo())
        await git.settled()
        #expect(try await TempRepo.run(["diff", "--cached"], in: repo.root) == cachedBefore)

        // An untracked file is added whole, and undo makes it untracked again.
        let fresh = set.files[2]
        let add = try await ReviewPatch.stage(nil, of: fresh, in: top)
        try await git.apply(add)
        try board.recordReview(tile: tile.id, entry: .object(["action": "stage", "path": "new.txt"]), patch: add, git: git)
        #expect(try await repo.git("ls-files", "new.txt") == "new.txt")
        #expect(board.undo())
        await git.settled()
        #expect(try await repo.git("ls-files", "new.txt") == "")
        #expect(FileManager.default.fileExists(atPath: repo.url("new.txt").path))
    }

    @Test func revertingCreatedAndDeletedFilesDeletesAndRestoresThem() async throws {
        let repo = try await workRepo()
        let git = ReviewGit()
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object([:])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        let top = try #require(set.repository)
        let gone = set.files[1], fresh = set.files[2]

        let restore = try ReviewPatch.revert(gone.hunks, of: gone, in: top)
        try await git.apply(restore)
        #expect(await read(repo.url("gone.txt")) == numbered(1...3))
        try await git.apply(restore.inverse)
        #expect(!FileManager.default.fileExists(atPath: repo.url("gone.txt").path))

        let remove = try ReviewPatch.revert(fresh.hunks, of: fresh, in: top)
        try await git.apply(remove)
        #expect(!FileManager.default.fileExists(atPath: repo.url("new.txt").path))
        try await git.apply(remove.inverse)
        #expect(await read(repo.url("new.txt")) == "fresh\nfile\n")
    }

    @Test func aHunkThatNoLongerAppliesIsRefused() async throws {
        let repo = try await workRepo()
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object([:])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        let app = set.files[0]
        // Someone edits the hunk's lines after the tile loaded.
        let edited = try #require(await read(repo.url("app.txt"))).replacingOccurrences(of: "line 3 changed", with: "line 3 edited again")
        try await repo.write("app.txt", edited)
        let patch = try ReviewPatch.revert([app.hunks[0]], of: app, in: try #require(set.repository))
        await #expect(throws: ChangesFailure.self) { try await ReviewGit().apply(patch) }
        #expect(await read(repo.url("app.txt")) == edited)
    }

    @Test func patchesNeverNameFilesOutsideTheRepository() {
        #expect(throws: ChangesFailure.self) { try ReviewPatch.checkPath("../x") }
        #expect(throws: ChangesFailure.self) { try ReviewPatch.checkPath("/etc/hosts") }
        #expect(throws: ChangesFailure.self) { try ReviewPatch.checkPath("a/.git/config") }
    }
}

/// `object.get` of a changes tile over the socket, as an agent reads what the user kept.
@MainActor
final class ChangesApiTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-changes-\(UUID().uuidString.prefix(8))")

    @Test func objectGetListsFilesHunksAndReviewedActions() async throws {
        let repo = try await workRepo()
        let registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards")))
        let board = registry.open(root: repo.root)
        let router = ApiRouter(registry: registry)
        let server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        let client = try LineClient(path: dir.appendingPathComponent("s").path)
        func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            client.send(String(decoding: try JSONEncoder().encode(JSONValue.object(["id": "1", "method": .string(method), "params": params])), as: UTF8.self))
            let reply = try await client.next()
            #expect(reply["ok"] == .bool(true), "\(method): \(reply["error"] ?? .null)")
            return reply["result"] ?? .null
        }
        let created = try await call("object.create", .object(["board": .string(board.id), "type": "changes", "props": .object(["paths": ["app.txt", "new.txt"]])]))
        let id = try #require(created["object"]?["id"]?.string)
        let git = ReviewGit()
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["paths": ["app.txt"]])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        let patch = try ReviewPatch.revert([set.files[0].hunks[1]], of: set.files[0], in: try #require(set.repository))
        try await git.apply(patch)
        try board.recordReview(tile: id, entry: .object(["action": "revert", "path": "app.txt", "header": .string(set.files[0].hunks[1].header)]), patch: patch, git: git)

        let got = try await call("object.get", .object(["id": .string(id)]))
        let files = try #require(got["changes"]?["files"]?.array)
        #expect(files.map { $0["path"]?.string } == ["app.txt", "new.txt"])
        #expect(files.map { $0["status"]?.string } == ["modified", "added"])
        let hunks = try #require(files[0]["hunks"]?.array)
        #expect(hunks.count == 1)
        #expect(hunks[0]["header"]?.string == "@@ -1,6 +1,6 @@")
        #expect(hunks[0]["new"]?["start"]?.int == 1 && hunks[0]["added"]?.int == 1 && hunks[0]["status"]?.string == "unstaged")
        #expect(got["object"]?["props"]?["reviewed"]?.array?.first?["action"]?.string == "revert")

        let measured = try await call("object.measure", .object(["board": .string(board.id), "type": "changes", "props": .object(["paths": ["app.txt"]])]))
        let rows = ChangeRows(await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["paths": ["app.txt"]])), highlight: false), collapsed: [])
        #expect(measured["h"]?.number == Double((CodeMetrics.titleHeight + ChangesMetrics.headerHeight + rows.height + ChangesMetrics.bottomPadding).rounded(.up)))
    }
}
