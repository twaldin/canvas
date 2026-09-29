import Foundation
import Testing
@testable import CanvasCore

private func load(_ repo: TempRepo, _ props: [String: JSONValue]) async -> ChangeSet {
    await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(props)), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
}

/// `feature`, forked from main: edits app.txt line 5, renames old.txt to new.txt with line 10
/// edited, deletes gone.txt, adds added.txt. Main then gains its own edit of app.txt line 25,
/// and the checkout (main) has uncommitted edits: neither is the feature's work.
private func featureRepo() async throws -> TempRepo {
    let repo = try await TempRepo(branch: "main")
    try await repo.write("app.txt", numbered(1...30))
    try await repo.write("old.txt", numbered(1...20))
    try await repo.write("gone.txt", "bye\nnow\n")
    try await repo.commit("base")
    try await repo.git("checkout", "-q", "-b", "feature")
    try await repo.write("app.txt", numbered(1...30).replacingOccurrences(of: "line 5\n", with: "line 5 feature\n"))
    try await repo.git("mv", "old.txt", "new.txt")
    try await repo.write("new.txt", numbered(1...20).replacingOccurrences(of: "line 10\n", with: "line 10 renamed\n"))
    try await repo.git("rm", "-q", "gone.txt")
    try await repo.write("added.txt", "one\ntwo\n")
    try await repo.commit("feature work")
    try await repo.git("checkout", "-q", "main")
    try await repo.write("app.txt", numbered(1...30).replacingOccurrences(of: "line 25\n", with: "line 25 main\n"))
    try await repo.commit("main moves on")
    try await repo.write("app.txt", numbered(1...30).replacingOccurrences(of: "line 1\n", with: "line 1 uncommitted\n"))
    return repo
}

struct CommitChangesTests {
    @Test func twoCommitsListEditsRenamesAndDeletionsFromObjectsAlone() async throws {
        let repo = try await featureRepo()
        let set = await load(repo, ["base": "main", "head": "feature"])
        let fork = try await repo.git("merge-base", "main", "feature"), tip = try await repo.git("rev-parse", "feature")
        #expect(set.notice == nil)
        #expect(set.comparesCommits && !set.actionable)
        #expect(set.base == fork && set.head == tip, "against the merge-base: main's own line 25 isn't the feature's")
        #expect(set.summary == "feature vs main · \(fork.prefix(7))..\(tip.prefix(7)) · 4 files · +4 −4")
        #expect(set.files.map(\.path) == ["added.txt", "app.txt", "gone.txt", "new.txt"])
        #expect(set.files.map(\.status) == [.added, .modified, .deleted, .renamed])

        let app = set.files[1]
        #expect(app.hunks.count == 1 && app.hunks[0].unified(old: app.old, new: app.new).contains("+line 5 feature"))
        #expect(!app.hunks[0].unified(old: app.old, new: app.new).contains { $0.contains("uncommitted") || $0.contains("main") }, "no working tree, no base-side commits")
        let gone = set.files[2]
        #expect(gone.hunks.count == 1 && gone.removed == 2 && gone.added == 0 && gone.new.lineCount == 0)
        let renamed = set.files[3]
        #expect(renamed.oldPath == "old.txt" && renamed.oldBoardPath == "old.txt")
        #expect(renamed.hunks.count == 1 && renamed.hunks[0].unified(old: renamed.old, new: renamed.new).filter { $0.hasPrefix("-") || $0.hasPrefix("+") } == ["-line 10", "+line 10 renamed"])
        #expect(set.files.allSatisfy { $0.readOnly && $0.hunks.allSatisfy { $0.status == .committed } })

        // Only the diff between the commits: the checkout was never read or written.
        #expect(try String(contentsOf: repo.url("app.txt"), encoding: .utf8).hasPrefix("line 1 uncommitted\n"))
        #expect(!FileManager.default.fileExists(atPath: repo.url("new.txt").path))
    }

    @Test func viewedHoldsWhileEitherSideOfAFileIsTheSame() async throws {
        let repo = try await featureRepo()
        let props: [String: JSONValue] = ["base": "main", "head": "feature"]
        let first = await load(repo, props)
        let viewed = JSONValue.object(Dictionary(uniqueKeysWithValues: first.files.map { ($0.boardPath, JSONValue.string($0.fingerprint)) }))
        #expect(await load(repo, props).files.allSatisfy { $0.isViewed(in: viewed) }, "the head didn't move: every file stays viewed")

        // The head moves on, touching app.txt only: the other files keep their mark.
        try await repo.git("checkout", "-q", "--force", "feature")
        try await repo.write("app.txt", numbered(1...30).replacingOccurrences(of: "line 5\n", with: "line 5 feature\n").replacingOccurrences(of: "line 9\n", with: "line 9 more\n"))
        try await repo.commit("more feature work")
        try await repo.git("checkout", "-q", "main")
        let moved = await load(repo, props)
        #expect(moved.files.map { $0.isViewed(in: viewed) } == [true, false, true, true])
    }

    @Test func stageUnstageAndDiscardAreRefusedBetweenCommits() async throws {
        let repo = try await featureRepo()
        let set = await load(repo, ["base": "main", "head": "feature"])
        let top = try #require(set.repository)
        let before = try await repo.git("status", "--porcelain")
        for file in set.files {
            await #expect(throws: ChangesFailure.readOnly) { try await ReviewPatch.stage(nil, of: file, in: top) }
            await #expect(throws: ChangesFailure.readOnly) { try await ReviewPatch.unstage(file.hunks, of: file, in: top) }
            await #expect(throws: ChangesFailure.readOnly) { try await ReviewPatch.discardUncommitted(nil, of: file, in: top) }
            #expect(throws: ChangesFailure.readOnly) { try ReviewPatch.revert(file.hunks, of: file, in: top) }
            #expect(!file.stageable && !file.unstageable && !file.discardable)
        }
        #expect(try await repo.git("status", "--porcelain") == before)
    }

    @Test func aRefTheRepositoryLacksSaysExactlyHowToFetchIt() async throws {
        let origin = try await TempRepo(branch: "main")
        try await origin.write("a.txt", numbered(1...3))
        try await origin.commit("base")
        let repo = try await TempRepo(cloning: origin)
        let pull = await load(repo, ["base": "origin/main", "head": "pull/12/head"])
        #expect(pull.notice == "no commit pull/12/head here; fetch it: git fetch origin pull/12/head:refs/pull/12/head")
        #expect(pull.files.isEmpty && pull.lead == pull.notice)
        #expect(await load(repo, ["base": "origin/nope", "head": "main"]).notice == "no commit origin/nope here; fetch it: git fetch origin nope")

        // Once fetched (here: written where that fetch puts it) the same tile reads it.
        try await repo.write("a.txt", numbered(1...4))
        let fetched = try await repo.commit("the pull request")
        try await repo.git("update-ref", "refs/pull/12/head", fetched)
        try await repo.git("reset", "-q", "--hard", "HEAD~1")
        let read = await load(repo, ["base": "origin/main", "head": "pull/12/head"])
        #expect(read.notice == nil && read.head == fetched && read.files.map(\.path) == ["a.txt"])
    }

    @Test func fetchCommandsBringTheRefUnderTheNameGiven() {
        let remotes = ["origin", "upstream"]
        #expect(ChangeSet.fetchCommand(for: "refs/pull/7/head", remotes: remotes) == "git fetch origin pull/7/head:refs/pull/7/head")
        #expect(ChangeSet.fetchCommand(for: "upstream/fm/x", remotes: remotes) == "git fetch upstream fm/x")
        #expect(ChangeSet.fetchCommand(for: "fm/rel-12389", remotes: remotes) == "git fetch origin fm/rel-12389:refs/heads/fm/rel-12389")
        #expect(ChangeSet.fetchCommand(for: "a1b2c3d4", remotes: ["fork"]) == "git fetch fork a1b2c3d4")
    }

    @Test func aRefIsItsWorktreeWhileCheckedOutThenItsCommits() async throws {
        let repo = try await featureRepo()
        let worktree = URL(fileURLWithPath: repo.root.path + "-wt/feature")
        try await repo.git("worktree", "add", "-q", worktree.path, "feature")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("wip"), withIntermediateDirectories: true)
        try "draft\n".write(to: worktree.appendingPathComponent("wip/draft.txt"), atomically: true, encoding: .utf8)
        let tip = try await repo.git("rev-parse", "feature")

        let live = await load(repo, ["ref": "feature", "base": "HEAD"])
        #expect(!live.comparesCommits && live.actionable, "checked out: the worktree's own uncommitted work, stageable")
        #expect(live.files.map(\.path) == ["wip/draft.txt"] && live.worktree == "feature (feature)")
        #expect(live.refSha == tip)

        try await repo.git("worktree", "remove", "--force", worktree.path)
        let objects = await load(repo, ["ref": "feature"])
        #expect(objects.comparesCommits && objects.refSha == tip)
        #expect(objects.files.map(\.path) == ["added.txt", "app.txt", "gone.txt", "new.txt"], "no worktree: the branch against main, from objects")
        #expect(await load(repo, ["ref": "feature", "base": "HEAD"]).summary.hasSuffix("no changes"), "HEAD of a ref no worktree has: nothing uncommitted")
    }

    @Test func aMergedAndDeletedRefStillShowsWhatItsMergeBroughtIn() async throws {
        let repo = try await featureRepo()
        let tip = try await repo.git("rev-parse", "feature")
        try await repo.git("checkout", "-q", "--force", "main")
        try await repo.git("merge", "-q", "--no-ff", "-m", "merge feature", "feature")
        let merge = try await repo.git("rev-parse", "HEAD")
        try await repo.git("branch", "-q", "-D", "feature")

        let gone = await load(repo, ["ref": "feature", "refSha": .string(tip)])
        #expect(gone.commits?.gone == .merged(merge) && gone.head == tip && gone.refSha == tip)
        #expect(gone.lead.hasPrefix("feature (merged in \(merge.prefix(7))) vs main"))
        #expect(gone.files.map(\.path) == ["added.txt", "app.txt", "gone.txt", "new.txt"], "main holds the tip now: against the merge's first parent, not an empty diff")
        #expect(await load(repo, ["ref": "feature"]).notice?.hasPrefix("no commit feature here") == true, "no last commit to fall back to")
    }
}
