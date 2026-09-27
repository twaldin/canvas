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

    /// An agent terminal working in `directory` (its `props.cwd`; the app adds the shell's
    /// reported directory).
    func agent(on board: Board, in directory: URL, frame: Frame? = nil) -> CanvasObject {
        board.create(type: .terminal, props: .object([
            "cwd": .string(directory.path), "command": .array([]),
            "agent": .object(["kind": .string("omp")]), "lifecycle": .object(["state": .string("idle")]),
        ]), frame: frame)
    }

    @Test func aMentionFromAnotherWorktreeTargetsTheOneAgentWorkingThere() async throws {
        let (repo, worktree) = try await fixture()
        let second = URL(fileURLWithPath: repo.root.path + "-wt/other")
        try await repo.git("worktree", "add", "-q", "-b", "other", second.path)
        let board = Board(id: "brd_test", root: repo.root)
        let main = agent(on: board, in: repo.root)
        let fees = agent(on: board, in: worktree.appendingPathComponent("src"))
        let shell = board.create(type: .terminal, props: .object(["cwd": .string(worktree.path), "command": .array([])]))
        let review = board.create(type: .changes, props: .object(["root": .string(worktree.path)]))
        let checkouts = Dictionary(uniqueKeysWithValues: [main, fees, shell].map { ($0.id, GitWorktree.containing(board.workingDirectory(of: $0.id))!) })
        func target(_ mention: MentionTarget, current: ObjectID?) -> ObjectID? {
            PromptTarget.checkout(of: mention, on: board).flatMap { PromptTarget.affinity(checkout: $0, current: current, checkouts: checkouts, objects: board.objects) }
        }

        // The worktree's changes tile, or a line of a file in it (/private/tmp spelling too):
        // its agent, not the plain shell in the same checkout.
        #expect(target(.object(review.id), current: main.id) == fees.id)
        let line = MentionTarget.code(object: review.id, path: "/private" + worktree.appendingPathComponent("src/fees.ts").path, lines: LineRange(start: 2, end: 2))
        #expect(target(line, current: main.id) == fees.id)
        #expect(target(line, current: nil) == fees.id, "no target yet")
        // Already the right agent, or a mention in the target's own checkout: nothing moves.
        #expect(target(line, current: fees.id) == nil)
        #expect(target(.code(object: review.id, path: "src/fees.ts", lines: LineRange(start: 1, end: 1)), current: main.id) == nil)
        // Back in the board's checkout from the worktree agent: the one agent there.
        #expect(target(.code(object: review.id, path: "src/fees.ts", lines: LineRange(start: 1, end: 1)), current: fees.id) == main.id)
        // A checkout nobody's agent works in, and one two agents work in: the target stays.
        let otherReview = board.create(type: .changes, props: .object(["root": .string(second.path)]))
        #expect(target(.object(otherReview.id), current: main.id) == nil)
        let twin = agent(on: board, in: worktree)
        var both = checkouts
        both[twin.id] = GitWorktree.containing(worktree.path)
        #expect(PromptTarget.affinity(checkout: GitWorktree.containing(worktree.path)!, current: main.id, checkouts: both, objects: board.objects) == nil)
        // Pages, terminals and drawings name no checkout.
        #expect(PromptTarget.checkout(of: .terminal(object: fees.id, text: "x"), on: board) == nil)
    }

    @Test func aWorktreeAgentsNotesResolveAgainstItsCheckout() async throws {
        let (repo, worktree) = try await fixture()
        let board = Board(id: "brd_test", root: repo.root)
        let main = agent(on: board, in: repo.root)
        let fees = agent(on: board, in: worktree.appendingPathComponent("src"))

        // The default: the creating agent's checkout when it isn't the board's.
        #expect(board.defaultLinkRoot(for: fees.id) == worktree.path)
        #expect(board.defaultLinkRoot(for: main.id) == nil)
        #expect(board.defaultLinkRoot(for: nil) == nil, "the user's notes resolve against the board root")
        // The shell's reported directory wins over props.cwd.
        board.reportedDirectory = { $0 == main.id ? worktree.path : nil }
        #expect(board.defaultLinkRoot(for: main.id) == worktree.path)
        board.reportedDirectory = { _ in nil }

        // Links written in the worktree agent's note open its checkout's file; absolute ones stay.
        let note = board.create(type: .note, props: .object(["markdown": .string("tests/x.ts:16"), "root": .string(worktree.path)]))
        #expect(board.linkRoot(of: note).path == worktree.path)
        #expect(board.boardPath("src/fees.ts", linkRoot: board.linkRoot(of: note)) == worktree.appendingPathComponent("src/fees.ts").path)
        #expect(board.boardPath("src/fees.ts", linkRoot: board.root) == "src/fees.ts")
        let relative = board.create(type: .html, props: .object(["html": .string(""), "root": .string("../\(repo.root.lastPathComponent)-wt/fees")]))
        #expect(board.linkRoot(of: relative).path == worktree.path, "board-relative roots resolve against the board root")

        // Only the board's own repository and its worktrees.
        try board.checkLinkRoot(worktree.path)
        try board.checkLinkRoot(repo.root.appendingPathComponent("src").path)
        let stranger = try await TempRepo()
        #expect(throws: BoardError.self) { try board.checkLinkRoot(stranger.root.path) }
        #expect(throws: BoardError.self) { try board.checkLinkRoot(worktree.appendingPathComponent("missing").path) }
        #expect(throws: BoardError.self) { try board.checkLinkRoot(worktree.appendingPathComponent("src/fees.ts").path) }
    }

    @Test func aBoardRootedInASubdirectoryMapsTheWorktreeToTheSamePlace() async throws {
        let (repo, worktree) = try await fixture()
        let board = Board(id: "brd_test", root: repo.root.appendingPathComponent("src"))
        let fees = agent(on: board, in: worktree)
        #expect(board.defaultLinkRoot(for: fees.id) == worktree.appendingPathComponent("src").path)
    }
}
