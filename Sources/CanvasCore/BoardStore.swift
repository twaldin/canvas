import CryptoKit
import Foundation

/// Persists boards under Application Support, keyed by repo (shared git dir) + branch/worktree,
/// so a board survives worktree deletion and each worktree/branch gets its own board.
@MainActor
public final class BoardStore {
    public let directory: URL
    private var pendingSaves: [BoardID: DispatchWorkItem] = [:]
    private let debounce: TimeInterval

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Canvas/boards", isDirectory: true)
    }

    public init(directory: URL = BoardStore.defaultDirectory, debounce: TimeInterval = 0.5) {
        self.directory = directory
        self.debounce = debounce
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Stable board id for a root directory.
    public static func boardID(for root: URL) -> BoardID {
        let identity = gitIdentity(root) ?? root.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "brd_\(digest.prefix(20))"
    }

    /// "<git common dir>\n<branch or detached worktree path>", or nil outside git.
    static func gitIdentity(_ root: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "rev-parse", "--path-format=absolute", "--git-common-dir", "--abbrev-ref", "HEAD", "--show-toplevel"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count == 3 else { return nil }
        let branch = lines[1] == "HEAD" ? lines[2] : lines[1]
        return "\(lines[0])\n\(branch)"
    }

    public func url(for id: BoardID) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    public func load(root: URL) -> Board {
        let id = Self.boardID(for: root)
        let board: Board
        if let data = try? Data(contentsOf: url(for: id)), var snapshot = try? Self.decoder.decode(BoardSnapshot.self, from: data) {
            // The root may have moved (renamed checkout); the board follows its identity.
            snapshot.root = root.path
            board = Board(snapshot: snapshot)
        } else {
            board = Board(id: id, root: root)
        }
        board.onChange = { [weak self, weak board] in
            guard let self, let board else { return }
            self.scheduleSave(board)
        }
        return board
    }

    public func scheduleSave(_ board: Board) {
        pendingSaves[board.id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak board] in
            guard let self, let board else { return }
            self.save(board)
        }
        pendingSaves[board.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    public func save(_ board: Board) {
        pendingSaves.removeValue(forKey: board.id)?.cancel()
        guard let data = try? Self.encoder.encode(board.snapshot) else { return }
        try? data.write(to: url(for: board.id), options: .atomic)
    }

    public func flush(_ boards: [Board]) {
        for board in boards where pendingSaves[board.id] != nil { save(board) }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
