import Foundation

/// Where a follow tile goes when the file it shows is gone (`Board.codeFileVanished`): its
/// history, newest first, without the vanished file and without entries whose files no longer
/// exist. The first entry left is the place it steps back to.
public enum FollowFallback {
    /// `history` entries (`{path, range?, action}`) kept: those of another path that is in
    /// `existing` (the history's paths found on disk), in order.
    public static func prune(_ history: [JSONValue], vanished: String, existing: Set<String>) -> [JSONValue] {
        history.filter { entry in
            guard let path = entry["path"]?.string else { return false }
            return path != vanished && existing.contains(path)
        }
    }

    /// The distinct paths of `history` other than `vanished`: what to look for on disk.
    public static func candidates(_ history: [JSONValue], vanished: String) -> [String] {
        var seen: Set<String> = [vanished]
        return history.compactMap { $0["path"]?.string }.filter { seen.insert($0).inserted }
    }
}
