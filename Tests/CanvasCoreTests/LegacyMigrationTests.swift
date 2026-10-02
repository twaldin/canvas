import Foundation
import Testing
import CanvasCore

/// An install under an earlier name (Chalkwork 0.3, Canvas 0.2) arrives whole, once
/// (LegacyMigration), on a temporary home: to a fresh name (`LegacyMigration.current`, or the
/// stand-in `fresh`), and back to Canvas, a name the app had before, whose locations may still
/// hold an old install.
struct LegacyMigrationTests {
    final class Domains: DefaultsDomains {
        var domains: [String: [String: Any]] = [:]
        func persistentDomain(forName domainName: String) -> [String: Any]? { domains[domainName] }
        func setPersistentDomain(_ domain: [String: Any], forName domainName: String) { domains[domainName] = domain }
    }

    static let chalkwork = LegacyMigration.earlier[0]
    static let canvas = LegacyMigration.earlier[1]
    /// A name the app never had, whatever this build is called.
    static let fresh = LegacyMigration.Name(name: "Freshname", slug: "freshname", bundle: "net.waldin.freshname")
    static let now = Date(timeIntervalSince1970: 1_791_039_600)  // 2026-10-03 15:00:00 UTC
    static let stamp = "20261003T150000Z"

    let home = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-migration-\(UUID().uuidString)", isDirectory: true)

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) }
    func url(_ path: String) -> URL { home.appendingPathComponent(path) }

    /// Every file under `dir`, relative path → contents.
    func tree(_ dir: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: dir.path) {
            var isDirectory: ObjCBool = false
            let url = dir.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files[path] = try read(url)
        }
        return files
    }

    /// An install of `name` as its app leaves it: a board whose snapshot image tile names its PNG
    /// by absolute path (escaped slashes, as the store writes them), a pre-repo-migration backup,
    /// open tabs, a spooled report, a composition, the browser profile. `tag` marks every file.
    /// Returns the board JSON as written.
    @discardableResult
    func install(_ name: LegacyMigration.Name, tag: String) throws -> String {
        let support = LegacyMigration(home: home).support(name)
        let snapshot = support.appendingPathComponent("boards/brd_1/snapshots/obj_9-20260928-101010.png").path
        let board = #"{"id":"brd_1","objects":[{"id":"obj_9","props":{"path":"\#(snapshot.replacingOccurrences(of: "/", with: "\\/"))"},"type":"image"}],"root":"\/Users\/me\/src\/\#(tag)"}"#
        try write(board, support.appendingPathComponent("boards/brd_1.json"))
        try write("PNG \(tag)", URL(fileURLWithPath: snapshot))
        try write(#"{"id":"brd_2","objects":[],"root":"\/Users\/me\/src\/\#(tag)\/wt"}"#, support.appendingPathComponent("boards/pre-repo-migration/brd_2.json"))
        try write(#"["/Users/me/src/\#(tag)"]"#, support.appendingPathComponent("open-boards.json"))
        try write("{}", support.appendingPathComponent("agent-reports/obj_1/5-42-\(tag).json"))
        try write("def arrange(canvas): pass  # \(tag)\n", url(".\(name.slug)/compositions/grid.py"))
        try write("cookies \(tag)", url("Library/HTTPStorages/\(name.bundle).binarycookies"))
        try write("site data \(tag)", url("Library/WebKit/\(name.bundle)/WebsiteData/LocalStorage/x.sqlite3"))
        return board
    }

    /// `install(source)` arrived at `target`'s locations: every file, the board re-pointed.
    func expectArrived(_ before: [String: String], board: String, from source: LegacyMigration.Name, to target: LegacyMigration.Name, tag: String) throws {
        let migration = LegacyMigration(home: home, target: target)
        let after = try tree(migration.support(target))
        #expect(Set(after.keys) == Set(before.keys), "every file arrives")
        for (path, text) in before where path != "boards/brd_1.json" { #expect(after[path] == text, "\(path) unchanged") }
        let old = migration.support(source).path.replacingOccurrences(of: "/", with: "\\/")
        let new = migration.support(target).path.replacingOccurrences(of: "/", with: "\\/")
        #expect(after["boards/brd_1.json"] == board.replacingOccurrences(of: old, with: new), "the image tile names the moved PNG")
        #expect(try read(url(".\(target.slug)/compositions/grid.py")) == "def arrange(canvas): pass  # \(tag)\n")
        #expect(try read(url("Library/HTTPStorages/\(target.bundle).binarycookies")) == "cookies \(tag)")
        #expect(try read(url("Library/WebKit/\(target.bundle)/WebsiteData/LocalStorage/x.sqlite3")) == "site data \(tag)")
        #expect(!exists("Library/Application Support/\(source.name)"))
        #expect(!exists(".\(source.slug)"))
    }

    @Test func aFreshInstallMovesNothingAndRecordsThatOnce() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = Domains()
        let migration = LegacyMigration(home: home, target: Self.fresh)
        #expect(migration.run(defaults: defaults, now: Self.now).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.path), "no folder created")
        #expect(defaults.domains[Self.fresh.bundle] as? [String: String] == ["LegacyMigration.Chalkwork.v1": "none", "LegacyMigration.Canvas.v1": "none"])
        #expect(migration.pending(defaults: defaults).isEmpty)
        // A Chalkwork installed and used afterwards stays its own.
        try install(Self.chalkwork, tag: "later")
        #expect(migration.run(defaults: defaults, now: Self.now).isEmpty)
        #expect(exists("Library/Application Support/Chalkwork/boards/brd_1.json"))
    }

    @Test func aChalkworkInstallArrivesIntactAndTheSecondRunDoesNothing() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let migration = LegacyMigration(home: home, target: Self.fresh)
        let board = try install(Self.chalkwork, tag: "chalkwork")
        let before = try tree(migration.support(Self.chalkwork))
        let defaults = Domains()
        // Chalkwork's own marker of its Canvas merge comes with its domain.
        defaults.domains[Self.chalkwork.bundle] = ["canvas.lassoSelection": true, "NSWindow Frame Canvas-brd_1": "0 0 800 600", "LegacyMigration.defaultsMerged": true]

        let log = migration.run(defaults: defaults, now: Self.now)

        try expectArrived(before, board: board, from: Self.chalkwork, to: Self.fresh, tag: "chalkwork")
        let settings = try #require(defaults.domains[Self.fresh.bundle])
        #expect(settings["canvas.lassoSelection"] as? Bool == true)
        #expect(settings["NSWindow Frame Canvas-brd_1"] as? String == "0 0 800 600", "window frames come along")
        #expect(settings["LegacyMigration.defaultsMerged"] == nil, "Chalkwork's marker isn't this migration's")
        #expect(settings["LegacyMigration.Chalkwork.v1"] as? String == "migrated \(Self.stamp)")
        #expect(settings["LegacyMigration.Canvas.v1"] as? String == "none")
        #expect(!exists("Library/Application Support/Freshname-stale-\(Self.stamp)"), "nothing was in the way: \(log)")

        // A second launch: nothing to decide, and a Chalkwork that ran again since (recreating its
        // folder, changing a setting) doesn't overwrite what the new name now owns.
        try write("{}", migration.support(Self.chalkwork).appendingPathComponent("open-boards.json"))
        defaults.domains[Self.chalkwork.bundle]?["canvas.exportDirectory"] = "/tmp"
        let settled = try tree(home)
        #expect(migration.run(defaults: defaults, now: Self.now.addingTimeInterval(60)).isEmpty)
        #expect(try tree(home) == settled)
        #expect(defaults.domains[Self.fresh.bundle]?["canvas.exportDirectory"] == nil)
    }

    @Test func aCanvasInstallThatNeverRanChalkworkArrives() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let migration = LegacyMigration(home: home, target: Self.fresh)
        let board = try install(Self.canvas, tag: "canvas")
        let before = try tree(migration.support(Self.canvas))
        let defaults = Domains()
        defaults.domains[Self.canvas.bundle] = ["canvas.lassoSelection": false]

        migration.run(defaults: defaults, now: Self.now)

        try expectArrived(before, board: board, from: Self.canvas, to: Self.fresh, tag: "canvas")
        let settings = try #require(defaults.domains[Self.fresh.bundle])
        #expect(settings["canvas.lassoSelection"] as? Bool == false)
        #expect(settings["LegacyMigration.Chalkwork.v1"] as? String == "none")
        #expect(settings["LegacyMigration.Canvas.v1"] as? String == "migrated \(Self.stamp)")
    }

    @Test func withBothChalkworkWinsAndCanvasStaysUntouched() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let migration = LegacyMigration(home: home, target: Self.fresh)
        // Canvas comes first in the old order (oldest app) and must not fill the destination.
        try install(Self.canvas, tag: "canvas")
        let board = try install(Self.chalkwork, tag: "chalkwork")
        let chalkwork = try tree(migration.support(Self.chalkwork))
        let canvas = try tree(home.appendingPathComponent("Library/Application Support/Canvas"))
        let defaults = Domains()
        defaults.domains[Self.canvas.bundle] = ["canvas.exportDirectory": "/old", "canvas.lassoSelection": true]
        defaults.domains[Self.chalkwork.bundle] = ["canvas.lassoSelection": false]

        let log = migration.run(defaults: defaults, now: Self.now)

        try expectArrived(chalkwork, board: board, from: Self.chalkwork, to: Self.fresh, tag: "chalkwork")
        #expect(try tree(home.appendingPathComponent("Library/Application Support/Canvas")) == canvas, "Canvas's install stays whole")
        #expect(try read(url(".canvas/compositions/grid.py")) == "def arrange(canvas): pass  # canvas\n")
        #expect(try read(url("Library/HTTPStorages/net.waldin.canvas.binarycookies")) == "cookies canvas")
        let settings = try #require(defaults.domains[Self.fresh.bundle])
        #expect(settings["canvas.lassoSelection"] as? Bool == false, "Chalkwork's value")
        #expect(settings["canvas.exportDirectory"] == nil, "nothing of Canvas's merged in")
        #expect(settings["LegacyMigration.Canvas.v1"] as? String == "superseded by Chalkwork")
        #expect(log.contains("left Canvas's data where it is: Chalkwork's came here"))
    }

    @Test func backToCanvasChalkworkWinsAndTheStaleCanvasIsBackedUp() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let migration = LegacyMigration(home: home, target: Self.canvas)
        #expect(migration.sources == [Self.chalkwork], "Canvas is the destination now, not a source")
        // Canvas 0.2 opened again after Chalkwork took its data: its locations are taken.
        try install(Self.canvas, tag: "stale")
        let stale = try tree(migration.support(Self.canvas))
        let board = try install(Self.chalkwork, tag: "chalkwork")
        let chalkwork = try tree(migration.support(Self.chalkwork))
        // The real files, as the rehearsal reads them (main.swift).
        let defaults = PreferenceFiles(home: home)
        defaults.setPersistentDomain(["canvas.exportDirectory": "/stale", "NSWindow Frame Canvas-brd_1": "1 1 10 10"], forName: Self.canvas.bundle)
        defaults.setPersistentDomain(["canvas.lassoSelection": true, "NSWindow Frame Canvas-brd_1": "0 0 800 600", "LegacyMigration.defaultsMerged": true], forName: Self.chalkwork.bundle)

        let log = migration.run(defaults: defaults, now: Self.now)

        let backup = "Library/Application Support/Canvas-stale-\(Self.stamp)"
        #expect(try tree(url("\(backup)/Library/Application Support/Canvas")) == stale, "the stale support directory, whole: \(log)")
        #expect(try read(url("\(backup)/.canvas/compositions/grid.py")) == "def arrange(canvas): pass  # stale\n")
        let backedUp = try PropertyListSerialization.propertyList(from: Data(contentsOf: url("\(backup)/Library/Preferences/net.waldin.canvas.plist")), format: nil) as? [String: String]
        #expect(backedUp == ["canvas.exportDirectory": "/stale", "NSWindow Frame Canvas-brd_1": "1 1 10 10"])
        let after = try tree(migration.support(Self.canvas))
        #expect(Set(after.keys) == Set(chalkwork.keys), "Chalkwork's boards, not a merge")
        let old = migration.support(Self.chalkwork).path.replacingOccurrences(of: "/", with: "\\/")
        let new = migration.support(Self.canvas).path.replacingOccurrences(of: "/", with: "\\/")
        #expect(after["boards/brd_1.json"] == board.replacingOccurrences(of: old, with: new))
        #expect(after["boards/brd_1/snapshots/obj_9-20260928-101010.png"] == "PNG chalkwork")
        #expect(try read(url(".canvas/compositions/grid.py")) == "def arrange(canvas): pass  # chalkwork\n")
        // The browser profile moves only where the destination has none: the old one stays in use.
        #expect(try read(url("Library/HTTPStorages/net.waldin.canvas.binarycookies")) == "cookies stale")
        #expect(try read(url("Library/HTTPStorages/net.waldin.chalkwork.binarycookies")) == "cookies chalkwork")
        let settings = try #require(defaults.persistentDomain(forName: Self.canvas.bundle))
        #expect(settings["NSWindow Frame Canvas-brd_1"] as? String == "0 0 800 600", "Chalkwork's frame, not the stale one")
        #expect(settings["canvas.lassoSelection"] as? Bool == true)
        #expect(settings["canvas.exportDirectory"] == nil, "no stale setting survives")
        #expect(settings["LegacyMigration.defaultsMerged"] == nil)
        #expect(settings["LegacyMigration.Chalkwork.v1"] as? String == "migrated \(Self.stamp)")
        #expect(settings["LegacyMigration.Canvas.v1"] == nil, "no marker for the destination's own name")

        // Rerun: nothing more, no second backup.
        let settled = try tree(home)
        #expect(migration.run(defaults: defaults, now: Self.now.addingTimeInterval(60)).isEmpty)
        #expect(try tree(home) == settled)
    }

    @Test func backToCanvasACanvasInstallStaysAsItIs() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let migration = LegacyMigration(home: home, target: Self.canvas)
        try install(Self.canvas, tag: "canvas")
        let before = try tree(home)
        let defaults = Domains()
        defaults.domains[Self.canvas.bundle] = ["canvas.lassoSelection": true]

        #expect(migration.run(defaults: defaults, now: Self.now).isEmpty)
        #expect(try tree(home) == before, "a direct upgrade from Canvas 0.2 finds its data in place")
        let expected: [String: AnyHashable] = ["canvas.lassoSelection": true, "LegacyMigration.Chalkwork.v1": "none"]
        #expect(defaults.domains[Self.canvas.bundle] as? [String: AnyHashable] == expected)
    }

    @Test func aPopulatedFreshDestinationIsBackedUpToo() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let migration = LegacyMigration(home: home, target: Self.fresh)
        // A development instance on the release bundle id wrote settings, and a support directory
        // exists, without any migration having run.
        try write("[]", migration.support(Self.fresh).appendingPathComponent("open-boards.json"))
        try install(Self.chalkwork, tag: "chalkwork")
        let defaults = Domains()
        defaults.domains[Self.fresh.bundle] = ["canvas.lassoSelection": true]
        defaults.domains[Self.chalkwork.bundle] = ["canvas.exportDirectory": "/work"]

        migration.run(defaults: defaults, now: Self.now)

        let backup = "Library/Application Support/Freshname-stale-\(Self.stamp)"
        #expect(try read(url("\(backup)/Library/Application Support/Freshname/open-boards.json")) == "[]")
        #expect(try read(migration.support(Self.fresh).appendingPathComponent("open-boards.json")) == #"["/Users/me/src/chalkwork"]"#)
        let settings = try #require(defaults.domains[Self.fresh.bundle])
        #expect(settings["canvas.lassoSelection"] == nil)
        #expect(settings["canvas.exportDirectory"] as? String == "/work")
    }

    @Test func eachEarlierNameHasItsOwnMarker() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let migration = LegacyMigration(home: home, target: Self.fresh)
        try install(Self.chalkwork, tag: "chalkwork")
        // Canvas decided (an earlier build that knew only Canvas), Chalkwork not: Chalkwork runs.
        let defaults = Domains()
        defaults.domains[Self.fresh.bundle] = ["LegacyMigration.Canvas.v1": "none"]
        #expect(migration.pending(defaults: defaults) == [Self.chalkwork])
        migration.run(defaults: defaults, now: Self.now)
        #expect(exists("Library/Application Support/Freshname/boards/brd_1.json"))
        #expect(defaults.domains[Self.fresh.bundle]?["LegacyMigration.Chalkwork.v1"] as? String == "migrated \(Self.stamp)")

        // Chalkwork migrated, Canvas undecided: Canvas is superseded, its install left alone.
        try FileManager.default.removeItem(at: home)
        try install(Self.canvas, tag: "canvas")
        let canvas = try tree(home)
        let later = Domains()
        later.domains[Self.fresh.bundle] = ["LegacyMigration.Chalkwork.v1": "migrated 20261003T150000Z", "canvas.lassoSelection": true]
        migration.run(defaults: later, now: Self.now)
        #expect(try tree(home) == canvas)
        #expect(later.domains[Self.fresh.bundle]?["LegacyMigration.Canvas.v1"] as? String == "superseded by Chalkwork")
        #expect(later.domains[Self.fresh.bundle]?["canvas.lassoSelection"] as? Bool == true, "the new name's own setting stays")

        // The marker Chalkwork's own migration left is not one of these.
        let copied = Domains()
        copied.domains[Self.fresh.bundle] = ["LegacyMigration.defaultsMerged": true]
        #expect(migration.pending(defaults: copied) == [Self.chalkwork, Self.canvas])
    }

    @Test func refusesWhileAnEarlierAppRuns() {
        let fresh = LegacyMigration(home: home, target: Self.fresh)
        #expect(fresh.refusal(running: ["com.apple.Safari"]) == nil)
        #expect(fresh.refusal(running: ["net.waldin.chalkwork"]) == "Chalkwork is running, so its boards stay with it; quit it and open Freshname again to bring them here")
        #expect(fresh.refusal(running: ["net.waldin.canvas"])?.hasPrefix("Canvas is running") == true)
        // Back to Canvas: an old Canvas 0.2 shares the bundle id (main.swift leaves out its own pid).
        #expect(LegacyMigration(home: home, target: Self.canvas).refusal(running: ["net.waldin.canvas"])?.hasPrefix("Canvas is running") == true)
    }

    @Test func thisBuildMigratesFromEveryOtherEarlierName() {
        let sources = LegacyMigration(home: home).sources
        #expect(sources == LegacyMigration.earlier.filter { $0 != LegacyMigration.current })
        #expect(sources.first == Self.chalkwork || LegacyMigration.current == Self.chalkwork, "the newest earlier name first")
    }
}
