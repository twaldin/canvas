import Foundation

/// Brings a Canvas 0.2 install's data to Chalkwork, the same app renamed in 0.3.0: the support
/// directory (boards, including `pre-repo-migration/` backups and page snapshots, open tabs,
/// Get Started, spooled agent reports), `~/.canvas` (compositions), the browser profile (cookies,
/// logins, site data) and the user defaults (export folder, lasso setting, window frames). Each
/// location moves only while the new one doesn't exist, so it runs once and never overwrites
/// Chalkwork's own data; the defaults are merged once, Chalkwork's own values winning. Image tiles
/// that point into the old support directory (Snapshot to Image) are re-pointed. Privacy grants
/// (microphone, camera, automation) belong to the old bundle id and can't move: macOS asks again.
/// The app runs it before anything reads `AppPaths` or the defaults, and never for a development
/// home or while Canvas is running (main.swift).
public struct LegacyMigration {
    public static let legacyName = "Canvas"
    public static let legacyBundle = "net.waldin.canvas"
    public static let bundle = "net.waldin.chalkwork"
    /// Set in the new defaults domain once the legacy one was merged into it.
    public static let defaultsMergedKey = "LegacyMigration.defaultsMerged"

    /// The user's home directory (`~`).
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    var library: URL { home.appendingPathComponent("Library", isDirectory: true) }
    public var legacySupport: URL { library.appendingPathComponent("Application Support/\(Self.legacyName)", isDirectory: true) }
    public var support: URL { library.appendingPathComponent("Application Support/Chalkwork", isDirectory: true) }

    /// Old location → new one.
    public var moves: [(from: URL, to: URL)] {
        [
            (legacySupport, support),
            (home.appendingPathComponent(".canvas", isDirectory: true), home.appendingPathComponent(".chalkwork", isDirectory: true)),
            (library.appendingPathComponent("WebKit/\(Self.legacyBundle)", isDirectory: true), library.appendingPathComponent("WebKit/\(Self.bundle)", isDirectory: true)),
            (library.appendingPathComponent("HTTPStorages/\(Self.legacyBundle)", isDirectory: true), library.appendingPathComponent("HTTPStorages/\(Self.bundle)", isDirectory: true)),
            (library.appendingPathComponent("HTTPStorages/\(Self.legacyBundle).binarycookies"), library.appendingPathComponent("HTTPStorages/\(Self.bundle).binarycookies")),
        ]
    }

    /// Moves what only the old locations hold and merges the legacy defaults; returns one line per
    /// thing it did (or failed to do), for the log. Nothing to do: empty.
    @discardableResult
    public func run(defaults: some DefaultsDomains) -> [String] {
        var log: [String] = []
        let files = FileManager.default
        for (from, to) in moves where files.fileExists(atPath: from.path) && !files.fileExists(atPath: to.path) {
            do {
                try files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.moveItem(at: from, to: to)
                log.append("moved \(from.path) to \(to.path)")
                if from == legacySupport { log += repointBoards() }
            } catch {
                log.append("could not move \(from.path) to \(to.path): \(error.localizedDescription)")
            }
        }
        if let legacy = defaults.persistentDomain(forName: Self.legacyBundle), !legacy.isEmpty {
            let current = defaults.persistentDomain(forName: Self.bundle) ?? [:]
            if current[Self.defaultsMergedKey] == nil {
                var merged = legacy.merging(current) { _, own in own }
                merged[Self.defaultsMergedKey] = true
                defaults.setPersistentDomain(merged, forName: Self.bundle)
                log.append("merged \(legacy.count) settings from \(Self.legacyBundle)")
            }
        }
        return log
    }

    /// Board files (and their `pre-repo-migration/` backups) name page snapshots by absolute path
    /// inside the support directory: rewrite those paths to the moved directory.
    func repointBoards() -> [String] {
        let boards = support.appendingPathComponent("boards", isDirectory: true)
        guard let walk = FileManager.default.enumerator(at: boards, includingPropertiesForKeys: nil) else { return [] }
        // The store writes JSON with escaped slashes; an exported board wouldn't.
        let old = legacySupport.path + "/", new = support.path + "/"
        let pairs = [(old, new), (old.replacingOccurrences(of: "/", with: "\\/"), new.replacingOccurrences(of: "/", with: "\\/"))]
        var repointed = 0
        for case let file as URL in walk where file.pathExtension == "json" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let rewritten = pairs.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            guard rewritten != text else { continue }
            do {
                try rewritten.write(to: file, atomically: true, encoding: .utf8)
                repointed += 1
            } catch {
                return ["could not re-point \(file.path): \(error.localizedDescription)"]
            }
        }
        return repointed == 0 ? [] : ["re-pointed \(repointed) board file\(repointed == 1 ? "" : "s") at \(support.path)"]
    }
}

/// The two `UserDefaults` calls the migration makes, so tests can use a dictionary.
public protocol DefaultsDomains {
    func persistentDomain(forName domainName: String) -> [String: Any]?
    func setPersistentDomain(_ domain: [String: Any], forName domainName: String)
}

extension UserDefaults: DefaultsDomains {}
