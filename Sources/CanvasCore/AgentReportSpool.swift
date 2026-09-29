import Foundation

/// Lifecycle reports an agent integration couldn't deliver because Canvas wasn't there to take
/// them (quit, restarting, crashed): `extensions/agent-hooks/report.ts` writes each as a file
/// `<tile>/<seq>-<pid>-<random>.json` in `agent-reports/` beside the socket, holding
/// `{"seq", "method", "params"}` (`agent.report` with its params, or `agent.release`). Canvas
/// replays a board's when it opens the board (`BoardRegistry.open`), oldest `seq` first, and
/// deletes them; the staleness rule (`Board.lifecycleSeq`, saved with the board) drops any
/// older than a report already applied. docs/contracts.md, Agent integrations.
public enum AgentReportSpool {
    public struct Entry: Sendable {
        public var tile: ObjectID
        public var seq: Int
        public var method: String
        public var params: JSONValue
        public var file: URL
    }

    /// The spooled reports of `tiles`, oldest first. A file that can't be read now (permissions,
    /// IO) is left for the next open; one that reads but isn't a report is deleted. Half-written
    /// files never show up: a writer renames a finished file into place, and hidden temporary
    /// files are skipped.
    /// File IO: call it off the main actor.
    public static func read(from directory: URL, tiles: [ObjectID]) -> [Entry] {
        var entries: [Entry] = []
        let manager = FileManager.default
        for tile in tiles {
            let folder = directory.appendingPathComponent(tile, isDirectory: true)
            guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
                let file = folder.appendingPathComponent(name)
                // Left for the next open: a failed read says nothing about what the file holds.
                guard let data = try? Data(contentsOf: file) else { continue }
                guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                      let seq = json["seq"]?.int, let method = json["method"]?.string, let params = json["params"] else {
                    // Not a report (garbage, or another writer's format): nothing will ever read it.
                    try? manager.removeItem(at: file)
                    continue
                }
                entries.append(Entry(tile: tile, seq: seq, method: method, params: params, file: file))
            }
        }
        return entries.sorted { ($0.seq, $0.file.lastPathComponent) < ($1.seq, $1.file.lastPathComponent) }
    }

    /// Deletes replayed reports, and each tile's folder once it's empty (a writer that loses
    /// its folder to this recreates it, `report.ts`). File IO: call it off the main actor.
    public static func remove(_ entries: [Entry]) {
        let manager = FileManager.default
        for entry in entries { try? manager.removeItem(at: entry.file) }
        for folder in Set(entries.map { $0.file.deletingLastPathComponent() }) where (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? manager.removeItem(at: folder)
        }
    }
}

extension Board {
    /// Applies spooled reports (`AgentReportSpool.read`, oldest first) as if they had arrived
    /// over the socket: `agent.report` through the staleness rule, `agent.release` only when no
    /// report from the same source is newer. Reports for tiles no longer on the board are dropped.
    public func replay(_ entries: [AgentReportSpool.Entry]) {
        for entry in entries where objects[entry.tile]?.type == .terminal {
            var params = entry.params.object ?? [:]
            params["tile"] = .string(entry.tile)
            switch entry.method {
            case "agent.report":
                try? reportLifecycle(params: .object(params))
            case "agent.release":
                let key = "\(entry.tile)|\(params["source"]?.string ?? params["kind"]?.string ?? "")"
                if let last = lifecycleSeq[key], entry.seq <= last { continue }
                lifecycleSeq[key] = entry.seq
                try? releaseAgent(tile: entry.tile)
            default:
                continue
            }
        }
    }
}
