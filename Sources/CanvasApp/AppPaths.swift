import Foundation

/// Filesystem locations the app depends on (docs/contracts.md).
enum AppPaths {
    /// `CANVAS_HOME` relocates sockets and boards so a development build can run beside the
    /// installed app (docs/testing.md).
    static let support: URL = {
        if let home = ProcessInfo.processInfo.environment["CANVAS_HOME"] { return URL(fileURLWithPath: home, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Canvas", isDirectory: true)
    }()
    static let apiSocket = support.appendingPathComponent("canvas.sock").path
    static let cmuxSocket = support.appendingPathComponent("cmux.sock").path
    static let boards = support.appendingPathComponent("boards", isDirectory: true)

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

    static let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
}
