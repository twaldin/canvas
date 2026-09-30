import Foundation
import Testing
import CanvasCore

/// A Canvas 0.2 install arrives in Chalkwork whole, once (LegacyMigration), on a temporary home.
struct LegacyMigrationTests {
    final class Domains: DefaultsDomains {
        var domains: [String: [String: Any]] = [:]
        func persistentDomain(forName domainName: String) -> [String: Any]? { domains[domainName] }
        func setPersistentDomain(_ domain: [String: Any], forName domainName: String) { domains[domainName] = domain }
    }

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

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

    @Test func legacySupportArrivesIntactAndTheSecondRunDoesNothing() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let migration = LegacyMigration(home: home)
        let old = migration.legacySupport
        // A snapshot image tile names its PNG by absolute path, with the store's escaped slashes.
        let snapshot = old.appendingPathComponent("boards/brd_1/snapshots/obj_9-20260928-101010.png").path
        let board = #"{"id":"brd_1","objects":[{"id":"obj_9","props":{"path":"\#(snapshot.replacingOccurrences(of: "/", with: "\\/"))"},"type":"image"}],"root":"\/Users\/me\/src\/app"}"#
        try write(board, old.appendingPathComponent("boards/brd_1.json"))
        try write("PNG", URL(fileURLWithPath: snapshot))
        try write(#"{"id":"brd_2","objects":[],"root":"\/Users\/me\/src\/app\/wt"}"#, old.appendingPathComponent("boards/pre-repo-migration/brd_2.json"))
        try write(#"{"runs":[]}"#, old.appendingPathComponent("boards/pre-repo-migration/migration.json"))
        try write(#"["/Users/me/src/app"]"#, old.appendingPathComponent("open-boards.json"))
        try write("{}", old.appendingPathComponent("agent-reports/obj_1/5-42-x.json"))
        try write("def arrange(canvas): pass\n", home.appendingPathComponent(".canvas/compositions/grid.py"))
        try write("cookies", home.appendingPathComponent("Library/HTTPStorages/net.waldin.canvas.binarycookies"))
        try write("site data", home.appendingPathComponent("Library/WebKit/net.waldin.canvas/WebsiteData/LocalStorage/x.sqlite3"))
        let before = try tree(old)
        let defaults = Domains()
        defaults.domains["net.waldin.canvas"] = ["canvas.lassoSelection": true, "NSWindow Frame Canvas-brd_1": "0 0 800 600"]
        defaults.domains["net.waldin.chalkwork"] = ["canvas.lassoSelection": false]

        let log = migration.run(defaults: defaults)

        let new = migration.support
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let after = try tree(new)
        #expect(Set(after.keys) == Set(before.keys), "every file arrives: \(log)")
        for (path, text) in before where path != "boards/brd_1.json" { #expect(after[path] == text, "\(path) unchanged") }
        let moved = new.appendingPathComponent("boards/brd_1/snapshots/obj_9-20260928-101010.png").path
        #expect(after["boards/brd_1.json"] == board.replacingOccurrences(of: snapshot.replacingOccurrences(of: "/", with: "\\/"), with: moved.replacingOccurrences(of: "/", with: "\\/")),
                "the image tile names the moved PNG")
        #expect(try read(home.appendingPathComponent(".chalkwork/compositions/grid.py")) == "def arrange(canvas): pass\n")
        #expect(try read(home.appendingPathComponent("Library/HTTPStorages/net.waldin.chalkwork.binarycookies")) == "cookies")
        #expect(try read(home.appendingPathComponent("Library/WebKit/net.waldin.chalkwork/WebsiteData/LocalStorage/x.sqlite3")) == "site data")
        let settings = try #require(defaults.domains["net.waldin.chalkwork"])
        #expect(settings["canvas.lassoSelection"] as? Bool == false, "Chalkwork's own value wins")
        #expect(settings["NSWindow Frame Canvas-brd_1"] as? String == "0 0 800 600", "window frames come along")

        // A second launch: nothing left to move, the defaults already merged, and a Canvas that
        // ran again since (recreating its folder) doesn't overwrite what Chalkwork now owns.
        try write("{}", old.appendingPathComponent("open-boards.json"))
        defaults.domains["net.waldin.canvas"]?["canvas.exportDirectory"] = "/tmp"
        let settled = try tree(new)
        #expect(migration.run(defaults: defaults).isEmpty)
        #expect(try tree(new) == settled)
        #expect(defaults.domains["net.waldin.chalkwork"]?["canvas.exportDirectory"] == nil)
    }

    @Test func aFreshInstallHasNothingToMove() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = Domains()
        #expect(LegacyMigration(home: home).run(defaults: defaults).isEmpty)
        #expect(defaults.domains.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }
}
