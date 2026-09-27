import Foundation
import CanvasCore

/// A board root's files (`git ls-files`: tracked plus untracked files git doesn't ignore), shared
/// by Go to (⌘P) and terminal references that name a file by its name (`core.py:10`). One per
/// root; listed when a board opens, again on every Go to, and when a reference lookup finds the
/// list older than `staleAfter`.
@MainActor
final class BoardFiles {
    private static var byRoot: [URL: BoardFiles] = [:]

    static func of(_ root: URL) -> BoardFiles {
        let root = root.standardizedFileURL
        if let files = byRoot[root] { return files }
        let files = BoardFiles(root: root)
        byRoot[root] = files
        return files
    }

    /// Paths past this are left out (a monorepo's generated trees).
    nonisolated static let maxListed = 200_000
    static let staleAfter: TimeInterval = 30

    let root: URL
    private(set) var index = FileIndex(paths: [])
    private var listedAt: TimeInterval?
    private var listing: Task<Void, Never>?
    private var waiting: [(FileIndex) -> Void] = []

    private init(root: URL) {
        self.root = root
    }

    /// Lists the files again (joining a listing already running) and hands the new index to
    /// `then`.
    func refresh(then: ((FileIndex) -> Void)? = nil) {
        if let then { waiting.append(then) }
        guard listing == nil else { return }
        let root = root
        listing = Task { [weak self] in
            let data = try? await GitRunner.shared.run(["ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "-z"],
                                                       in: root, maxOutput: 64 << 20, timeout: 10)
            let index = await offPool {
                FileIndex(paths: (data ?? Data()).split(separator: 0).prefix(Self.maxListed).map { String(decoding: $0, as: UTF8.self) })
            }
            guard let self else { return }
            self.listing = nil
            self.listedAt = ProcessInfo.processInfo.systemUptime
            // A failed listing (not a repository, git gone) keeps what was listed before.
            if data != nil { self.index = index }
            let waiting = self.waiting
            self.waiting = []
            for then in waiting { then(self.index) }
        }
    }

    /// The current index, re-listing in the background when it is older than `staleAfter`.
    func current() -> FileIndex {
        if listedAt.map({ ProcessInfo.processInfo.systemUptime - $0 > Self.staleAfter }) ?? true { refresh() }
        return index
    }
}
