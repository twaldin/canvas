import Foundation
import Testing
@testable import CanvasCore

private func read(_ url: URL) async -> String? {
    await offPool { try? String(contentsOf: url, encoding: .utf8) }
}

private func load(_ repo: TempRepo, _ props: [String: JSONValue] = [:]) async -> ChangeSet {
    await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(props)), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
}

/// A PR-like branch: `pr`, forked from main, commits an edit of app.txt line 5 and a new file;
/// then the reviewer's own uncommitted edits of line 7 (one hunk with the committed line 5
/// against the merge-base) and line 25.
private func prRepo() async throws -> TempRepo {
    let repo = try await TempRepo(branch: "main")
    try await repo.write("app.txt", numbered(1...30))
    try await repo.commit("base")
    try await repo.git("checkout", "-q", "-b", "pr")
    let committed = numbered(1...30).replacingOccurrences(of: "line 5\n", with: "line 5 committed\n")
    try await repo.write("app.txt", committed)
    try await repo.write("added.txt", "one\ntwo\n")
    try await repo.commit("pr work")
    try await repo.write("app.txt", prWorkingTree)
    return repo
}

private let prCommitted = numbered(1...30).replacingOccurrences(of: "line 5\n", with: "line 5 committed\n")
private let prWorkingTree = prCommitted.replacingOccurrences(of: "line 7\n", with: "line 7 mine\n").replacingOccurrences(of: "line 25\n", with: "line 25 mine\n")

@MainActor
struct BranchReviewTests {
    @Test func aBranchAgainstItsMergeBaseSaysWhatItComparesAndMarksCommittedHunks() async throws {
        let repo = try await prRepo()
        let branch = await load(repo, ["base": "merge-base"])
        #expect(branch.includesCommits)
        #expect(branch.summary == "pr vs main · 2 files · +5 −3")
        #expect(branch.files.map(\.path) == ["added.txt", "app.txt"])
        #expect(branch.files[0].hunks.map(\.status) == [.committed])
        #expect(branch.files[1].hunks.map(\.status) == [.unstaged, .unstaged], "line 5 (committed) and 7 (not) share a hunk")
        #expect(!branch.files[0].discardable && branch.files[1].discardable, "nothing of the committed file is the reviewer's to discard")

        let uncommitted = await load(repo)
        #expect(!uncommitted.includesCommits)
        #expect(uncommitted.summary == "Uncommitted changes · 1 file · +2 −2")
        #expect(await load(repo, ["base": "no-such-ref"]).summary == "unknown commit no-such-ref")
    }

    @Test func discardAgainstABranchBaseNeverTouchesCommittedWork() async throws {
        let repo = try await prRepo()
        let set = await load(repo, ["base": "merge-base"])
        let top = try #require(set.repository)
        let added = set.files[0], app = set.files[1]
        // A committed hunk: refused both ways, the file stays.
        await #expect(throws: ChangesFailure.self) { try await ReviewPatch.discardUncommitted([added.hunks[0]], of: added, in: top) }
        #expect(throws: ChangesFailure.self) { try ReviewPatch.revert(added.hunks, of: added, in: top) }
        await #expect(throws: ChangesFailure.self) { try await ReviewPatch.discardUncommitted(nil, of: added, in: top) }

        // The mixed hunk loses only the uncommitted line 7; the committed line 5 and line 25 stay.
        let git = ReviewGit()
        let board = Board(id: "brd_t", root: repo.root)
        let tile = board.create(type: .changes, props: .object(["base": "merge-base"]))
        let patch = try await ReviewPatch.discardUncommitted([app.hunks[0]], of: app, in: top)
        try await git.apply(patch)
        try board.recordReview(tile: tile.id, entry: ReviewPatch.entry("revert", file: app, hunk: app.hunks[0], lines: nil, patch: patch), patch: patch, git: git)
        #expect(await read(repo.url("app.txt")) == prCommitted.replacingOccurrences(of: "line 25\n", with: "line 25 mine\n"))
        #expect(await read(repo.url("added.txt")) == "one\ntwo\n")
        #expect(board.undo())
        await git.settled()
        #expect(await read(repo.url("app.txt")) == prWorkingTree)

        // The whole file: back to HEAD, not to the merge-base.
        try await git.apply(try await ReviewPatch.discardUncommitted(nil, of: app, in: top))
        #expect(await read(repo.url("app.txt")) == prCommitted)

        // Lines picked in the mixed hunk: the committed one isn't the reviewer's to discard.
        try await repo.write("app.txt", prWorkingTree)
        let again = await load(repo, ["base": "merge-base"]).files[1]
        let hunk = again.hunks[0]
        let committedRows = hunk.pairedRows(Set(hunk.lines.indices.filter { hunk.lines[$0].new == 5 && hunk.lines[$0].kind == .added }))
        await #expect(throws: ChangesFailure.self) { try await ReviewPatch.discardUncommitted([hunk], of: again, in: top, lines: committedRows) }
        #expect(await read(repo.url("app.txt")) == prWorkingTree)
    }

    @Test func discardAgainstABranchBaseRefusesAFileChangedSinceTheTileReadIt() async throws {
        let repo = try await prRepo()
        let set = await load(repo, ["base": "merge-base"])
        try await repo.write("app.txt", prWorkingTree.replacingOccurrences(of: "line 9\n", with: "line 9 later\n"))
        await #expect(throws: ChangesFailure.self) { try await ReviewPatch.discardUncommitted([set.files[1].hunks[0]], of: set.files[1], in: try #require(set.repository)) }
    }

    @Test func unstageTakesJustTheHunkOrLinesOutOfTheIndexAndUndoPutsThemBack() async throws {
        let repo = try await TempRepo()
        try await repo.write("a.txt", numbered(1...40))
        try await repo.commit("base")
        // Staged: a hunk with two edits (lines 3 and 6) and one at line 30. Unstaged: a line
        // inserted at the top, so working-tree lines are one past the index's.
        let staged = numbered(1...40).replacingOccurrences(of: "line 3\n", with: "line 3 pink\n").replacingOccurrences(of: "line 6\n", with: "line 6 dark\n")
            .replacingOccurrences(of: "line 30\n", with: "line 30 staged\n")
        try await repo.write("a.txt", staged)
        try await repo.git("add", "a.txt")
        try await repo.write("a.txt", "top\n" + staged)
        let set = await load(repo)
        let top = try #require(set.repository)
        let file = set.files[0]
        #expect(file.hunks.map(\.status) == [.partial, .staged], "the inserted line joins the first hunk")
        let cachedBefore = try await TempRepo.run(["diff", "--cached"], in: repo.root)

        let git = ReviewGit()
        let board = Board(id: "brd_t", root: repo.root)
        let tile = board.create(type: .changes, props: .object([:]))
        let patch = try await ReviewPatch.unstage([file.hunks[1]], of: file, in: top)
        try await git.apply(patch)
        try board.recordReview(tile: tile.id, entry: ReviewPatch.entry("unstage", file: file, hunk: file.hunks[1], lines: nil, patch: patch), patch: patch, git: git)
        var cached = try await TempRepo.run(["diff", "--cached", "-U0"], in: repo.root)
        #expect(!cached.contains("line 30 staged") && cached.contains("+line 3 pink") && cached.contains("+line 6 dark"))
        #expect(await read(repo.url("a.txt")) == "top\n" + staged, "the working tree stays as it is")
        #expect(board.nextUndo?.notice(redo: false, author: nil) == "Undid Unstage of a.txt, lines 28–34 · ⇧⌘Z redoes")
        #expect(board.undo())
        await git.settled()
        #expect(try await TempRepo.run(["diff", "--cached"], in: repo.root) == cachedBefore)

        // Only the dark line of the first hunk.
        let hunk = file.hunks[0]
        let dark = hunk.pairedRows(Set(hunk.lines.indices.filter { hunk.lines[$0].kind == .added && hunk.lines[$0].new == 7 }))
        try await git.apply(try await ReviewPatch.unstage([hunk], of: file, in: top, lines: dark))
        cached = try await TempRepo.run(["diff", "--cached", "-U0"], in: repo.root)
        #expect(cached.contains("+line 3 pink") && !cached.contains("dark") && cached.contains("+line 30 staged"))

        // Nothing staged there: refused.
        try await repo.write("a.txt", "top\n" + staged.replacingOccurrences(of: "line 18\n", with: "line 18 mine\n"))
        let fresh = await load(repo)
        let unstagedOnly = try #require(fresh.files[0].hunks.first { $0.status == .unstaged })
        await #expect(throws: ChangesFailure.self) { try await ReviewPatch.unstage([unstagedOnly], of: fresh.files[0], in: top) }
    }

    @Test func unstagingANewFileLeavesItOnDiskUntracked() async throws {
        let repo = try await TempRepo()
        try await repo.write("a.txt", "a\n")
        try await repo.commit("base")
        try await repo.write("new.txt", "fresh\nfile\n")
        try await repo.git("add", "new.txt")
        let set = await load(repo)
        let new = try #require(set.files.first { $0.path == "new.txt" })
        #expect(new.hunks.map(\.status) == [.staged] && new.unstageable)
        try await ReviewGit().apply(try await ReviewPatch.unstage(nil, of: new, in: try #require(set.repository)))
        #expect(try await repo.git("ls-files", "new.txt") == "")
        #expect(await read(repo.url("new.txt")) == "fresh\nfile\n")
    }

    @Test func thePickerOffersTheUncommittedWorkTheBranchAndWhatWasTyped() {
        #expect(ChangesBaseChoice(prop: "HEAD") == .uncommitted && ChangesBaseChoice(prop: "merge-base") == .branch)
        #expect(ChangesBaseChoice(typed: "  origin/main \n") == .other("origin/main"))
        #expect(ChangesBaseChoice(typed: " HEAD") == .uncommitted, "typing HEAD is the uncommitted changes")
        #expect(ChangesBaseChoice(typed: "   ") == nil)
        #expect(ChangesBaseChoice.choices(current: .branch) == [.uncommitted, .branch])
        #expect(ChangesBaseChoice.choices(current: .other("v1.2")) == [.uncommitted, .branch, .other("v1.2")])
        #expect(ChangesBaseChoice.branch.title(defaultBranch: "origin/main") == "Branch vs origin/main")
        #expect(ChangesBaseChoice.other("HEAD~3").prop == "HEAD~3")
    }

    @Test func undoingAGitActionNamesItAndSoDoesUndoingTheUsersOwnMove() throws {
        let board = Board(id: "brd_t", root: URL(fileURLWithPath: "/tmp"))
        let tile = board.create(type: .changes, props: .object([:]))
        let patch = ReviewPatch(repository: URL(fileURLWithPath: "/tmp"), text: "", target: .index, reverse: false)
        try board.recordReview(tile: tile.id, entry: .object(["action": "stage", "path": "src/regex_helper.rs", "scope": "file"]), patch: patch)
        let step = try #require(board.nextUndo)
        #expect(step.title == "Stage of src/regex_helper.rs")
        #expect(step.notice(redo: false, author: nil) == "Undid Stage of src/regex_helper.rs · ⇧⌘Z redoes")
        #expect(step.notice(redo: true, author: "omp") == "Redid omp: Stage of src/regex_helper.rs · ⌘Z undoes")
        #expect(ReviewPatch.name(of: .object(["action": "revert", "path": "a.rs", "scope": "lines", "added": 1, "removed": 1])) == "Discard of 2 lines of a.rs")

        try board.update(tile.id, frame: Frame(x: 50, y: 50, w: tile.frame.w, h: tile.frame.h))
        #expect(board.nextUndo?.notice(redo: false, author: nil) == "Undid moved a changes tile · ⇧⌘Z redoes", "no undo is silent")
    }

    @Test func aCompactNoChangesTileGrowsWhenChangesAppearAndASizedOneKeepsItsSize() async throws {
        let repo = try await TempRepo()
        try await repo.write("a.txt", numbered(1...80))
        try await repo.commit("base")
        let clean = await load(repo)
        let cap = CGSize(width: 820, height: 620)
        let compact = ChangesMetrics.fit(clean, maxWidth: cap.width)
        #expect(compact.height < 150, "a clean checkout's tile is one message row")
        try await repo.write("a.txt", numbered(1...80).replacingOccurrences(of: "line ", with: "a row long enough to widen the tile past its compact width, number "))
        let changed = await load(repo)
        let grown = try #require(ChangesMetrics.grown(compact, from: clean, to: changed, cap: cap))
        #expect(grown.height == cap.height && grown.width > compact.width && grown.width <= cap.width, "the user's grows to at most the default size")
        #expect(ChangesMetrics.grown(compact, from: nil, to: changed, cap: cap) == grown, "also on its first listing after a relaunch")
        #expect(ChangesMetrics.grown(compact, from: clean, to: clean, cap: cap) == nil)
        #expect(ChangesMetrics.grown(CGSize(width: 820, height: 620), from: clean, to: changed, cap: cap) == nil, "a tile sized otherwise keeps its size")
        let agents = try #require(ChangesMetrics.grown(compact, from: clean, to: changed))
        #expect(agents.width == compact.width && agents.height == ChangesMetrics.fit(changed, maxWidth: compact.width).height, "an agent's fitted tile grows to its fit")
    }

    @Test func thePinnedFileHeaderCoversASliverOfTheFilesLastRow() async throws {
        let repo = try await TempRepo()
        try await repo.write("a.txt", numbered(1...10))
        try await repo.write("b.txt", numbered(1...10))
        try await repo.commit("base")
        try await repo.write("a.txt", numbered(1...10).replacingOccurrences(of: "line 5\n", with: "line five\n"))
        try await repo.write("b.txt", numbered(1...10).replacingOccurrences(of: "line 5\n", with: "line five\n"))
        let set = await load(repo)
        let rows = ChangeRows(set, collapsed: [], listOpen: false)
        let second = try #require(rows.index(ofFile: 1))
        let lastRow = rows.height(ofRow: second - 1)
        // Scrolled so that 5 pt of a.txt's last line shows under the pinned header.
        let sliver = try #require(rows.stickyFile(scroll: rows.tops[second] - ChangesMetrics.fileHeight - 5))
        #expect(sliver.file == 0 && sliver.offset == 0 && sliver.height == ChangesMetrics.fileHeight + 5)
        // A whole row and more shows: nothing is covered.
        let reading = try #require(rows.stickyFile(scroll: rows.tops[second] - ChangesMetrics.fileHeight - lastRow - 20))
        #expect(reading.height == ChangesMetrics.fileHeight)
    }
}
