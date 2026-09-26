import CoreServices
import Foundation

/// A recursive FSEvents subscription on some directories, delivering the paths of changed files
/// (canonical, e.g. `/private/tmp/…`) on the main queue. Unlike a file descriptor watch it sees
/// files that don't exist yet and files replaced by a rename. Stops when released.
final class FileEvents: @unchecked Sendable {
    private final class Handler: @unchecked Sendable {
        let deliver: @MainActor ([String]) -> Void
        init(_ deliver: @escaping @MainActor ([String]) -> Void) { self.deliver = deliver }
    }

    let directories: [String]
    private let handler: Handler
    private var stream: FSEventStreamRef?

    init?(directories: [String], latency: TimeInterval = 0.1, handler: @escaping @MainActor ([String]) -> Void) {
        self.directories = directories
        self.handler = Handler(handler)
        // The stream holds the handler unretained; `deinit` stops the stream before it goes.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self.handler).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated { handler.deliver(changed) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, directories as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// `path` with symlinks resolved as far as it exists (FSEvents reports real paths), plus the
    /// part that doesn't exist yet.
    static func canonical(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let resolved = realpath(existing.path, nil) else { return path }
        defer { free(resolved) }
        return ([String(cString: resolved)] + missing).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }

    /// Nearest existing directory at or above `path`'s parent, canonical.
    static func watchableDirectory(for path: String) -> String {
        var directory = URL(fileURLWithPath: canonical(path)).deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        while !(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue), directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        return directory.path
    }
}
