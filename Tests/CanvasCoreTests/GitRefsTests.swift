import Foundation
import Testing
@testable import CanvasCore

/// A branch-anchored tile's ref through a worktree's life: checked out, worktree deleted, branch
/// merged (or squashed) and deleted.
struct GitRefsTests {
    /// `main` with one commit, and branch `feature` one commit ahead, checked out in a linked
    /// worktree beside the repository.
    func fixture() async throws -> (repo: TempRepo, worktree: URL, tip: String) {
        let repo = try await TempRepo()
        try await repo.write("a.txt", "one\n")
        try await repo.commit("init")
        let worktree = URL(fileURLWithPath: repo.root.path + "-wt/feature")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        try "feature\n".write(to: worktree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await TempRepo.run(["add", "-A"], in: worktree)
        try await TempRepo.run(["commit", "-q", "-m", "feature"], in: worktree)
        let tip = try await TempRepo.run(["rev-parse", "HEAD"], in: worktree)
        return (repo, worktree, tip)
    }

    @Test func aCheckedOutRefIsLiveInItsWorktreeThenObjectsOnceTheWorktreeIsGone() async throws {
        let (repo, worktree, tip) = try await fixture()
        // Asked from the main checkout, the branch lives in the other worktree.
        let live = try await GitRefs.resolve(repo: repo.root, ref: "feature")
        #expect(live.state == .live)
        #expect(live.sha == tip)
        #expect(live.worktree?.resolvingSymlinksInPath().path == worktree.resolvingSymlinksInPath().path)
        #expect(try await GitRefs.resolve(repo: repo.root, ref: "refs/heads/feature").state == .live)

        try await repo.git("worktree", "remove", "--force", worktree.path)
        #expect(try await GitRefs.resolve(repo: repo.root, ref: "feature") == GitRefs.Resolution(worktree: nil, sha: tip, state: .objects))
        // The main checkout's own branch is live there.
        let main = try await GitRefs.resolve(repo: repo.root, ref: "main")
        #expect(main.state == .live)
        #expect(main.worktree?.resolvingSymlinksInPath().path == repo.root.resolvingSymlinksInPath().path)
    }

    @Test func aMergedAndDeletedBranchNamesItsMergeCommit() async throws {
        let (repo, worktree, tip) = try await fixture()
        try await repo.git("worktree", "remove", "--force", worktree.path)
        try await repo.write("c.txt", "main moved on\n")
        try await repo.commit("main moves")
        try await repo.git("merge", "-q", "--no-ff", "-m", "merge feature", "feature")
        let merge = try await repo.git("rev-parse", "HEAD")
        try await repo.write("d.txt", "after\n")
        try await repo.commit("after the merge")
        try await repo.git("branch", "-d", "feature")

        #expect(try await GitRefs.resolve(repo: repo.root, ref: "feature", lastKnownSha: tip) == GitRefs.Resolution(worktree: nil, sha: tip, state: .merged(merge)))
        await #expect(throws: GitRefs.Failure.unknownRef("feature")) {
            try await GitRefs.resolve(repo: repo.root, ref: "feature")
        }
    }

    @Test func aFastForwardedBranchIsMergedAtItsOwnTip() async throws {
        let (repo, worktree, tip) = try await fixture()
        try await repo.git("worktree", "remove", "--force", worktree.path)
        try await repo.git("merge", "-q", "--ff-only", "feature")
        try await repo.write("d.txt", "after\n")
        try await repo.commit("after the merge")
        try await repo.git("branch", "-d", "feature")
        #expect(try await GitRefs.resolve(repo: repo.root, ref: "feature", lastKnownSha: tip).state == .merged(tip))
    }

    @Test func aSquashMergedBranchIsGoneButItsCommitStillReads() async throws {
        let (repo, worktree, tip) = try await fixture()
        try await repo.git("worktree", "remove", "--force", worktree.path)
        try await repo.git("merge", "-q", "--squash", "feature")
        try await repo.git("commit", "-q", "-m", "squashed feature")
        try await repo.git("branch", "-D", "feature")

        #expect(try await GitRefs.resolve(repo: repo.root, ref: "feature", lastKnownSha: tip) == GitRefs.Resolution(worktree: nil, sha: tip, state: .missing))
        #expect(try await repo.git("show", "\(tip):b.txt") == "feature")
        // Once its objects are gone there's nothing left to show.
        await #expect(throws: GitRefs.Failure.unknownRef("feature")) {
            try await GitRefs.resolve(repo: repo.root, ref: "feature", lastKnownSha: String(repeating: "0", count: 40))
        }
    }
}
