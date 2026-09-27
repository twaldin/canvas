import Foundation
import Testing
@testable import CanvasCore

/// An agent working in a `git worktree` of the board's repository: another directory sharing
/// the repository's common git directory, outside the board root.
@MainActor
struct WorktreeTests {
    /// The board's repository with one commit, and a linked worktree of it (branch `feature`)
    /// in a sibling directory named `fees`.
    func fixture() async throws -> (repo: TempRepo, worktree: URL) {
        let repo = try await TempRepo()
        try await repo.write("src/fees.ts", "one\ntwo\nthree\n")
        try await repo.commit("init")
        let worktree = URL(fileURLWithPath: repo.root.path + "-wt/fees")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        return (repo, worktree)
    }

    @Test func followShowsAnotherWorktreesFileWithItsOwnChanges() async throws {
        let (repo, worktree) = try await fixture()
        let board = Board(id: "brd_test", root: repo.root)
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(repo.root.path), "command": .array([])]))
        let file = worktree.appendingPathComponent("src/fees.ts")
        try "one\nTWO\nthree\n".write(to: file, atomically: true, encoding: .utf8)

        let follow = try #require(try board.follow(tile: terminal.id, path: file.path, range: LineRange(start: 2, end: 2), action: "edit"))
        #expect(follow.props["path"]?.string == file.path, "outside the root the path stays absolute")
        // Its gutter comes from its own worktree: the edit shows there, the board's copy is clean.
        let engine = GitDiffEngine(watchesRepositories: false)
        #expect(await engine.diff(file: file, base: .head).state == .modified)
        #expect(await engine.diff(file: repo.url("src/fees.ts"), base: .head).state == .unchanged)

        // Another repository is still outside the project.
        let other = try await TempRepo()
        try await other.write("src/fees.ts", "x\n")
        #expect(try board.follow(tile: terminal.id, path: other.url("src/fees.ts").path, range: nil, action: "read") == nil)
        #expect(board.objects[follow.id]?.props["path"]?.string == file.path)
    }

    @Test func aPinnedCommitReadsAnotherWorktreesFileAndMissingOnesAreNotFound() async throws {
        let (repo, worktree) = try await fixture()
        let file = worktree.appendingPathComponent("src/fees.ts")
        try "one\nfeature two\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try await TempRepo.run(["commit", "-q", "-a", "-m", "feature"], in: worktree)
        let sha = try await TempRepo.run(["rev-parse", "HEAD"], in: worktree)
        try "changed on disk\n".write(to: file, atomically: true, encoding: .utf8)

        let pinned = await NoteSource.excerpt(for: NoteFence(path: file.path, commit: sha, lines: LineRange(start: 2, end: 2)), root: repo.root, captured: nil)
        #expect(pinned.lines == ["feature two"])

        func failure(_ path: String, commit: String?) async -> ObjectMeasure.Failure? {
            var props: [String: JSONValue] = ["path": .string(path), "range": .object(["start": .number(1), "end": .number(1)])]
            if let commit { props["pinnedCommit"] = .string(commit) }
            do {
                _ = try await ObjectMeasure.codeExcerpt(.object(props), root: repo.root)
                return nil
            } catch {
                return error as? ObjectMeasure.Failure
            }
        }
        try "new\n".write(to: worktree.appendingPathComponent("src/new.ts"), atomically: true, encoding: .utf8)
        let untracked = worktree.appendingPathComponent("src/new.ts").path
        #expect(await failure(untracked, commit: sha) == .notFound("\(untracked) does not exist at \(sha)"))
        #expect(await failure(file.path, commit: "0123456") == .notFound("unknown commit 0123456"))
        #expect(await failure("src/gone.ts", commit: nil) == .notFound("no file src/gone.ts"))
        #expect(await failure(untracked, commit: nil) == nil, "on disk it reads")
    }

    @Test func filesOutsideTheRootAreNamedByTheirWorktreeAndRepoPath() async throws {
        let (repo, worktree) = try await fixture()
        let file = worktree.appendingPathComponent("src/fees.ts").path
        #expect(PathLabel.short(file) == "fees/src/fees.ts")
        #expect(PathLabel.short("src/fees.ts") == "src/fees.ts", "paths under the root are already short")
        #expect(PathLabel.short(repo.url("src/fees.ts").path) == "\(repo.root.lastPathComponent)/src/fees.ts")
        let loose = NSTemporaryDirectory() + "no-repo-\(UUID().uuidString)/a.ts"
        #expect(PathLabel.short(loose) == loose, "outside git the path is all there is")

        // Tray chips; the mention itself keeps the absolute path for the agent.
        let board = Board(id: "brd_test", root: repo.root)
        let tile = board.create(type: .code, props: .object(["path": .string(file)]))
        let line = try board.stage(.code(object: tile.id, path: file, lines: LineRange(start: 2, end: 2), symbol: "fee"))
        #expect(line.label == "fees/src/fees.ts:2 fee")
        #expect(try board.stage(.object(tile.id)).label == "code fees/src/fees.ts")
        let drained = await board.drain(peek: true)
        #expect(drained.context.contains("code \(file):2-2"))
    }
}
