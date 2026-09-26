import Foundation
import Testing
@testable import CanvasCore

/// A throwaway git repository in a temp directory.
struct TempRepo {
    let root: URL

    init(branch: String = "main") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", branch)
    }

    init(cloning origin: TempRepo) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-git-\(UUID().uuidString)")
        _ = try TempRepo.run(["clone", "-q", origin.root.path, root.path], in: origin.root)
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        try TempRepo.run(args, in: root)
    }

    static func run(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Canvas Tests", "-c", "user.email=tests@canvas.invalid", "-c", "commit.gpgsign=false"] + args
        process.currentDirectoryURL = directory
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitError.failed(status: process.terminationStatus, stderr: args.joined(separator: " ")) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func commit(_ message: String) throws -> String {
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
        return try git("rev-parse", "HEAD")
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
}

func numbered(_ range: ClosedRange<Int>) -> String {
    range.map { "line \($0)\n" }.joined()
}

struct GitBaseTests {
    @Test func mergeBaseUsesMainWhenThereIsNoRemote() async throws {
        let repo = try TempRepo(branch: "main")
        try repo.write("a.txt", numbered(1...3))
        let fork = try repo.commit("base")
        try repo.git("checkout", "-q", "-b", "feature")
        try repo.write("a.txt", numbered(1...4))
        try repo.commit("feature work")
        let resolved = await GitDiffEngine(watchesRepositories: false).resolvedBase(for: repo.url("a.txt"), base: .mergeBase)
        #expect(resolved == .init(sha: fork, label: "merge-base with main"))
    }

    @Test func mergeBaseFallsBackToMaster() async throws {
        let repo = try TempRepo(branch: "master")
        try repo.write("a.txt", numbered(1...3))
        let fork = try repo.commit("base")
        try repo.git("checkout", "-q", "-b", "topic")
        try repo.write("b.txt", "new\n")
        try repo.commit("topic")
        try repo.git("checkout", "-q", "master")
        try repo.write("a.txt", numbered(1...5))
        try repo.commit("master moved on")
        try repo.git("checkout", "-q", "topic")
        let resolved = await GitDiffEngine(watchesRepositories: false).resolvedBase(for: repo.url("b.txt"), base: .mergeBase)
        #expect(resolved == .init(sha: fork, label: "merge-base with master"))
    }

    @Test func originHeadWinsOverLocalBranches() async throws {
        let origin = try TempRepo(branch: "trunk")
        try origin.write("a.txt", numbered(1...3))
        let shared = try origin.commit("shared")
        let clone = try TempRepo(cloning: origin)
        // A local `main` that diverged from the remote default branch must not be the base.
        try clone.git("checkout", "-q", "-b", "main")
        try clone.write("a.txt", numbered(1...9))
        try clone.commit("unrelated local main")
        try clone.git("checkout", "-q", "-b", "feature", "origin/trunk")
        try clone.write("b.txt", "feature\n")
        try clone.commit("feature")
        let resolved = await GitDiffEngine(watchesRepositories: false).resolvedBase(for: clone.url("b.txt"), base: .mergeBase)
        #expect(resolved == .init(sha: shared, label: "merge-base with origin/trunk"))
    }

    @Test func committingOnTheBaseBranchReResolvesTheBase() async throws {
        let repo = try TempRepo(branch: "main")
        try repo.write("a.txt", numbered(1...3))
        let first = try repo.commit("one")
        try repo.write("a.txt", numbered(1...4))
        let engine = GitDiffEngine()
        let before = await engine.diff(file: repo.url("a.txt"), base: .mergeBase)
        #expect(before.state == .modified && before.base == first)

        let toplevel = try repo.git("rev-parse", "--show-toplevel")
        let moved = Task {
            for await note in NotificationCenter.default.notifications(named: .gitDiffBaseChanged) where note.object as? String == toplevel { return true }
            return false
        }
        let second = try repo.commit("two")
        let announced = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await moved.value }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        moved.cancel()
        #expect(announced, "a commit on the base branch must re-resolve the merge-base")
        let after = await engine.diff(file: repo.url("a.txt"), base: .mergeBase)
        #expect(after.base == second)
        #expect(after.state == .unchanged)
    }
}

struct GitDiffTests {
    @Test func modifiedFileMapsEveryHunkToOldAndNewLines() async throws {
        let repo = try TempRepo()
        try repo.write("f.txt", numbered(1...40))
        let base = try repo.commit("base")
        // Change line 2, insert two lines after 10, delete 37-38, and append at the end.
        var lines = (1...40).map { "line \($0)" }
        lines[1] = "line 2 changed"
        lines.insert(contentsOf: ["new a", "new b"], at: 10)
        lines.removeSubrange(38...39)
        lines.append("tail")
        try repo.write("f.txt", lines.joined(separator: "\n") + "\n")

        let diff = await GitDiffEngine(watchesRepositories: false).diff(file: repo.url("f.txt"), base: .mergeBase)
        #expect(diff.state == .modified)
        #expect(diff.base == base)
        #expect(diff.mappings == [
            LineRangeMapping(original: 2..<3, modified: 2..<3),
            LineRangeMapping(original: 11..<11, modified: 11..<13),
            LineRangeMapping(original: 37..<39, modified: 39..<39),
            LineRangeMapping(original: 41..<41, modified: 41..<42),
        ])
        #expect(diff.hunks.map(\.mappings.count) == [1, 1, 2], "changes within 6 lines of each other share a hunk, like git -U3")
        #expect(diff.hunks[2].mentionLines.side == .new && diff.hunks[2].mentionLines.lines == LineRange(start: 39, end: 41))
        #expect(diff.old.text == numbered(1...40), "the old side is the base version of the file")

        let display = DiffDisplay(diff, mode: .diff)
        #expect(display.rows.filter { $0.kind == .deleted }.map(\.oldLine) == [2, 37, 38])
        #expect(display.rows.filter { $0.kind == .added }.map(\.newLine) == [2, 11, 12, 41])
        #expect(display.rows.filter { $0.kind == .header }.map(\.hunk) == [0, 1, 2])
        // Context rows after the insertion carry both numbers, offset by the two new lines.
        let row = try #require(display.row(showing: 13, side: .new))
        #expect(display.rows[row].kind == .context && display.rows[row].oldLine == 11)
        let deletedRow = try #require(display.row(showing: 37, side: .old))
        let text = (display.text as NSString).substring(with: display.range(ofRow: deletedRow))
        #expect(text == " 37     - line 37", "deleted rows show only the old number")

        let source = DiffDisplay(diff, mode: .source)
        #expect(source.rows.count == 41 && source.rows.allSatisfy { $0.kind == .context })
    }

    @Test func pureDeletionHunkIsMentionedOnTheOldSide() async throws {
        let repo = try TempRepo()
        try repo.write("f.txt", numbered(1...30))
        try repo.commit("base")
        var lines = (1...30).map { "line \($0)" }
        lines.removeSubrange(19...21)
        try repo.write("f.txt", lines.joined(separator: "\n") + "\n")
        let diff = await GitDiffEngine(watchesRepositories: false).diff(file: repo.url("f.txt"), base: .head)
        let hunk = try #require(diff.hunks.first)
        #expect(diff.hunks.count == 1)
        #expect(hunk.mentionLines.side == .old && hunk.mentionLines.lines == LineRange(start: 20, end: 22))
        let display = DiffDisplay(diff, mode: .diff)
        let rows = try #require(display.rows(for: hunk.mentionLines.lines, side: .old, hunks: diff.hunks))
        #expect(display.rows[rows.lowerBound].kind == .header, "a hunk mention outlines the header and its rows")
        #expect(rows.count == 4)
    }

    @Test func untrackedAddedDeletedBinaryAndMissingFilesHaveClearStates() async throws {
        let repo = try TempRepo()
        try repo.write("keep.txt", "same\n")
        try repo.write("gone.txt", numbered(1...3))
        try repo.commit("base")
        try repo.write("fresh.txt", "one\ntwo\n")
        try FileManager.default.removeItem(at: repo.url("gone.txt"))
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: repo.url("image.png"))
        let engine = GitDiffEngine(watchesRepositories: false)

        let fresh = await engine.diff(file: repo.url("fresh.txt"), base: .mergeBase)
        #expect(fresh.state == .added)
        #expect(DiffDisplay(fresh, mode: .diff).rows.filter { $0.kind == .added }.map(\.newLine) == [1, 2])

        let gone = await engine.diff(file: repo.url("gone.txt"), base: .mergeBase)
        #expect(gone.state == .deleted)
        #expect(DiffDisplay(gone, mode: .diff).rows.filter { $0.kind == .deleted }.map(\.oldLine) == [1, 2, 3])

        #expect(await engine.diff(file: repo.url("keep.txt"), base: .mergeBase).state == .unchanged)
        #expect(await engine.diff(file: repo.url("image.png"), base: .mergeBase).state == .binary)
        #expect(await engine.diff(file: repo.url("never.txt"), base: .mergeBase).state == .missing)

        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-plain-\(UUID().uuidString).txt")
        try "plain\n".write(to: outside, atomically: true, encoding: .utf8)
        let plain = await engine.diff(file: outside, base: .mergeBase)
        #expect(plain.state == .notRepository && plain.new.lineCount == 1)
    }

    @Test func unchangedContentIsServedFromCacheWithoutGit() async throws {
        let repo = try TempRepo()
        try repo.write("f.txt", numbered(1...5))
        try repo.commit("base")
        try repo.write("f.txt", numbered(1...6))
        let engine = GitDiffEngine(watchesRepositories: false)
        let first = await engine.diff(file: repo.url("f.txt"), base: .mergeBase)
        let runs = await engine.diffRuns
        let again = await engine.diff(file: repo.url("f.txt"), base: .mergeBase)
        #expect(again == first)
        #expect(await engine.diffRuns == runs, "same base and content must not run git diff again")

        try repo.write("f.txt", numbered(1...7))
        let changed = await engine.diff(file: repo.url("f.txt"), base: .mergeBase)
        #expect(await engine.diffRuns == runs + 1)
        #expect(changed.mappings == [LineRangeMapping(original: 6..<6, modified: 6..<8)])
    }

    @Test func filesRequestedTogetherShareOneGitDiff() async throws {
        let repo = try TempRepo()
        for name in ["a", "b", "c"] { try repo.write("\(name) file.txt", numbered(1...3)) }
        try repo.commit("base")
        for name in ["a", "b", "c"] { try repo.write("\(name) file.txt", numbered(1...4)) }
        let engine = GitDiffEngine(watchesRepositories: false)
        _ = await engine.resolvedBase(for: repo.url("a file.txt"), base: .mergeBase)
        let diffs = await withTaskGroup(of: FileDiff.self) { group in
            for name in ["a", "b", "c"] { group.addTask { await engine.diff(file: repo.url("\(name) file.txt"), base: .mergeBase) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(diffs.allSatisfy { $0.mappings == [LineRangeMapping(original: 4..<4, modified: 4..<5)] })
        #expect(await engine.diffRuns == 1)
    }
}
