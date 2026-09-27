import Foundation

/// Which files a follow tile re-aims at: text files that exist in the agent's project. Agents
/// also read what a code tile can't usefully show (their own `view.render` PNGs, screenshots,
/// archives, files they are about to delete, scratch files in the temp directory); following
/// those left the tile on "file not found: .tmp-render.png" or a binary notice.
public enum FollowFilter {
    /// Images, documents, archives, and other binaries, by extension (lowercased).
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "ico", "icns", "svg", "heic", "heif", "avif", "psd",
        "pdf", "zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "dmg", "iso", "jar", "war", "whl",
        "o", "a", "so", "dylib", "dll", "exe", "bin", "class", "wasm", "pyc", "db", "sqlite", "sqlite3",
        "mp3", "mp4", "mov", "m4a", "wav", "webm", "ogg", "ttf", "otf", "woff", "woff2",
    ]

    /// The OS temp directory and `/tmp`.
    public static let tempDirectories = [NSTemporaryDirectory(), "/tmp", "/var/tmp"]

    /// Whether follow mode shows `path` (absolute): it lies inside one of `projects` (the board
    /// root, the terminal's cwd) or in another worktree of a project's repository (an agent
    /// working in a `git worktree` of the board's repo: same common git directory); it isn't
    /// under a temp directory unless that project is too (scratch files outside a project that
    /// lives in the temp directory); it exists, is a regular file, and isn't binary (by
    /// extension, or a NUL byte in its first 8000 bytes, git's own test).
    public static func follows(_ path: String, projects: [String], tempDirectories: [String] = tempDirectories) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        var containing = projects.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.filter { contains($0, file.path) }
        if containing.isEmpty, let worktree = GitWorktree.containing(file.path),
           projects.contains(where: { GitWorktree.containing($0)?.commonDir == worktree.commonDir }) {
            containing = [worktree.toplevel]
        }
        guard !containing.isEmpty, !binaryExtensions.contains(file.pathExtension.lowercased()) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        let real = file.resolvingSymlinksInPath().path
        let temps = tempDirectories.map(Self.resolved).filter { contains($0, real) }
        guard containing.contains(where: { project in temps.allSatisfy { contains($0, Self.resolved(project)) } }) else { return false }
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return false }
        defer { try? handle.close() }
        return !((try? handle.read(upToCount: 8000)) ?? Data()).contains(0)
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// `path` is `directory` or inside it (a name prefix isn't containment).
    private static func contains(_ directory: String, _ path: String) -> Bool {
        directory == "/" || path == directory || path.hasPrefix(directory + "/")
    }
}
