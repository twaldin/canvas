import CanvasCore
import Foundation
import GhosttyTerminal

extension Housekeeping {
    /// At launch, off the main thread: deletes the zmx logs of Canvas sessions that no longer
    /// run, libghostty's config files already read, and renders older than a day
    /// (`Housekeeping`'s rules; never a file of another name). Without zmx, or when `zmx list`
    /// fails, the logs stay: a log is deleted only when its session is known to be gone.
    @MainActor
    static func pruneAtLaunch() {
        let ghostty = TerminalController.managedConfigDirectory
        let renders = ApiRouter.scratchImages
        let logs = AppPaths.zmxLogs
        let zmx = AppPaths.zmx
        DispatchQueue.global(qos: .utility).async {
            let now = Date()
            remove(staleGhosttyConfigs(listing(ghostty), now: now), in: ghostty)
            remove(staleRenders(listing(renders), now: now), in: renders)
            if let zmx, let live = liveSessions(zmx: zmx) {
                remove(deadSessionLogs(listing(logs), live: live, now: now), in: logs)
            }
        }
    }

    /// Regular files in `directory` with their modification dates; none when it doesn't exist.
    private nonisolated static func listing(_ directory: URL) -> [File] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return nil }
            return File(name: url.lastPathComponent, modified: modified)
        }
    }

    private nonisolated static func remove(_ names: [String], in directory: URL) {
        for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        if !names.isEmpty { NSLog("Canvas: removed %d leftover files from %@", names.count, directory.path) }
    }

    /// Every running zmx session's name (any instance's); nil when `zmx list` fails. Blocks
    /// until zmx exits.
    private nonisolated static func liveSessions(zmx: String) -> Set<String>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = ["list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return sessionNames(zmxList: String(decoding: data, as: UTF8.self))
    }
}
