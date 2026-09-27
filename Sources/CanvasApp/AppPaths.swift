import CanvasCore
import Foundation

/// Filesystem locations the app depends on (docs/contracts.md).
enum AppPaths {
    /// `CANVAS_HOME` relocates sockets and boards so a development build can run beside the
    /// installed app (docs/testing.md).
    static let support: URL = {
        if let home = ProcessInfo.processInfo.environment["CANVAS_HOME"] { return URL(fileURLWithPath: home, isDirectory: true) }
        return defaultSupport
    }()
    private static let defaultSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Canvas", isDirectory: true)
    /// The installed app's home, not a `CANVAS_HOME` elsewhere (its own browser profile, `BrowserProfile`).
    static let isDefaultHome = support.standardizedFileURL.path == defaultSupport.standardizedFileURL.path
    static let apiSocket = support.appendingPathComponent("canvas.sock").path
    static let cmuxSocket = support.appendingPathComponent("cmux.sock").path
    /// Launching the app with CMUX_SOCKET_PASSWORD makes the cmux socket require it; terminal
    /// tiles get it in their environment. Without it the socket relies on its 0600 mode.
    static let cmuxPassword: String? = ProcessInfo.processInfo.environment["CMUX_SOCKET_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 }
    static let boards = support.appendingPathComponent("boards", isDirectory: true)
    /// Browser pages frozen by Snapshot to Image, kept with the board (beside its
    /// `<boardId>.json`), so they outlive the temp directory and the page changing.
    static func pageSnapshots(of board: BoardID) -> URL {
        boards.appendingPathComponent(board, isDirectory: true).appendingPathComponent("snapshots", isDirectory: true)
    }
    /// Roots of the boards open as tabs, in tab order, reopened at the next launch.
    static let openBoards = support.appendingPathComponent("open-boards.json")

    /// A bundled asset from the repo's `resources/` directory (copied into the app bundle by
    /// scripts/bundle.sh), e.g. `asset("kit/mermaid.min.js")`.
    static func asset(_ relativePath: String) -> URL? {
        resources?.appendingPathComponent("resources").appendingPathComponent(relativePath)
    }

    /// Directory holding `schema/`, `bin/canvas`, and `clients/python` — the repo when run via
    /// `swift run`, or the bundle's Resources once packaged. CANVAS_RESOURCES overrides.
    static let resources: URL? = {
        if let override = ProcessInfo.processInfo.environment["CANVAS_RESOURCES"] { return URL(fileURLWithPath: override) }
        if let bundled = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("schema/canvas-api.json").path) {
            return bundled
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("schema/canvas-api.json").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()

    /// GUI apps don't get the login shell's PATH, so look in the usual install locations too.
    static let zmx: String? = {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map { "\($0)/zmx" } ?? []
        return (["/opt/homebrew/bin/zmx", "/usr/local/bin/zmx"] + path).first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Where zmx writes each session's log (`<session>.log`): `$XDG_STATE_HOME/zmx/logs`, else
    /// `~/.local/state/zmx/logs`. Canvas deletes its sessions' logs (`Housekeeping`).
    static let zmxLogs: URL = {
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state", isDirectory: true)
        return state.appendingPathComponent("zmx/logs", isDirectory: true)
    }()
    static let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
}
