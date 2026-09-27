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

    /// A board as stored on disk, whether or not it is open.
    public struct Stored: Equatable, Sendable {
        public var id: BoardID
        public var root: String
        /// The root directory is gone (deleted worktree, removed checkout); the board is kept.
        public var archived: Bool
        public var updatedAt: Date?
        public var objectCount: Int
    }

    /// Every board file in the store, sorted by id. Unreadable files are skipped.
    public func list() -> [Stored] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file -> Stored? in
            guard let data = try? Data(contentsOf: file), let snapshot = try? Self.decoder.decode(BoardSnapshot.self, from: data) else { return nil }
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return Stored(id: snapshot.id, root: snapshot.root, archived: !Self.isDirectory(snapshot.root), updatedAt: modified, objectCount: snapshot.objects.count)
        }.sorted { $0.id < $1.id }
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Writes a human-readable snapshot (for committing to the repo). The selection tray and
    /// attention markers are personal, transient state, so they are left out.
    public static func export(_ board: Board, to url: URL) throws {
        var snapshot = board.snapshot
        snapshot.tray = nil
        snapshot.attention = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(snapshot)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
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
