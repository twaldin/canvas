import AppKit
import CanvasCore
import GhosttyTerminal

/// A Ghostty surface running `zmx attach <session>`: the agent/shell survives app quit, crash,
/// and rebuild; reattaching restores the screen. After a reboot, a recorded omp session resumes.
@MainActor
final class TerminalTile: NSView, TileContent {
    let objectID: ObjectID
    let sessionName: String
    let terminal: TerminalView
    private var surface: TerminalSurface?
    private let handler = TerminalEvents()
    var onTitle: ((String) -> Void)?

    init(object: CanvasObject, board: Board) {
        objectID = object.id
        sessionName = Self.sessionName(object.id)
        terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: object.frame.w, height: object.frame.h))
        super.init(frame: terminal.frame)
        terminal.autoresizingMask = [.width, .height]
        let environment = Self.environment(tile: object.id, board: board)
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: object.props["cwd"]?.string ?? board.root.path,
            envVars: environment,
            command: Self.command(session: sessionName, object: object, board: board, keep: Set(environment.keys))
        )
        terminal.controller = TerminalController.shared
        handler.tile = self
        terminal.delegate = handler
        addSubview(terminal)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Launch

    /// Variables inherited from the app's own environment that must not leak into tiles
    /// (e.g. herdr/zmx state from the terminal that launched the app).
    static let strippedPrefixes = ["HERDR_", "ZMX_", "CMUX_", "CANVAS_", "TERM_PROGRAM"]

    static func environment(tile: ObjectID, board: Board) -> [String: String] {
        var env = [
            "CANVAS_ENV": "1",
            "CANVAS_SOCKET": AppPaths.apiSocket,
            "CANVAS_TILE_ID": tile,
            "CANVAS_BOARD_ID": board.id,
            "CANVAS_BOARD_ROOT": board.root.path,
            // omp's browser tool drives browser tiles through the cmux subset (docs/contracts.md).
            "CMUX_SOCKET_PATH": AppPaths.cmuxSocket,
            "CMUX_SURFACE_ID": tile,
            "CMUX_WORKSPACE_ID": board.id,
        ]
        if let password = AppPaths.cmuxPassword { env["CMUX_SOCKET_PASSWORD"] = password }
        if let resources = AppPaths.resources {
            let inherited = ProcessInfo.processInfo.environment
            env["PATH"] = resources.appendingPathComponent("bin").path + ":" + (inherited["PATH"] ?? "/usr/bin:/bin")
            let python = resources.appendingPathComponent("clients/python").path
            env["PYTHONPATH"] = inherited["PYTHONPATH"].map { "\(python):\($0)" } ?? python
        }
        return env
    }

    /// Shell-quoted command string (Ghostty takes a string, not argv). zmx ignores the trailing
    /// command when the session already exists, so it only runs for a new session.
    /// `keep`: the tile's own variables. `env -u` runs after Ghostty applied them, so an inherited
    /// variable of the same name (a dev instance launched with CANVAS_SOCKET set) must not unset them.
    static func command(session: String, object: CanvasObject, board: Board, keep: Set<String>) -> String {
        let shell = AppPaths.userShell
        let start = initialCommand(object).map { [shell, "-l", "-c", "\($0); exec \(quote([shell])) -l"] } ?? [shell, "-l"]
        guard let zmx = AppPaths.zmx else { return quote(start) }
        let strip = ProcessInfo.processInfo.environment.keys
            .filter { key in !keep.contains(key) && strippedPrefixes.contains { key.hasPrefix($0) } }
            .sorted()
            .flatMap { ["-u", $0] }
        let labels = "canvas.board=\(board.id) canvas.tile=\(object.id)"
        return quote(["/usr/bin/env"] + strip + [zmx, "attach", "--labels", labels, session] + start)
    }

    /// What a new session runs before dropping to a login shell: after a reboot, resume the
    /// recorded omp session; otherwise the tile's initial `command`.
    static func initialCommand(_ object: CanvasObject) -> String? {
        if object.props["agent"]?["kind"]?.string == "omp", let sessionId = object.props["agent"]?["sessionId"]?.string {
            return "omp --resume=\(quote([sessionId]))"
        }
        let argv = object.props["command"]?.array?.compactMap(\.string) ?? []
        return argv.isEmpty ? nil : quote(argv)
    }

    static func quote(_ argv: [String]) -> String {
        argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }.joined(separator: " ")
    }

    /// Ends the persistent session; used only when the user closes the tile.
    func killSession() {
        guard let zmx = AppPaths.zmx else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = ["kill", sessionName]
        try? process.run()
    }

    /// zmx session names stay short: socket paths under the GUI app's TMPDIR are capped (docs/contracts.md).
    nonisolated static func sessionName(_ tile: ObjectID) -> String { "canvas-\(tile)" }

    /// The last `limit` lines of the session's text; nil when zmx is missing or the session
    /// doesn't exist. Streams zmx's output through a bounded tail (never the whole scrollback)
    /// and blocks until zmx exits, so call it off the main actor when it isn't for drawing.
    nonisolated static func history(session: String, lines limit: Int) -> (text: String, lines: Int)? {
        guard let zmx = AppPaths.zmx else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = ["history", session]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Drain while zmx writes: it blocks once the pipe buffer fills, so waiting first would deadlock.
        var tail = TerminalTail(limit: limit)
        let reader = output.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
            tail.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return tail.finish()
    }

    // MARK: Input

    /// Paste text honoring bracketed-paste mode; optionally press Enter.
    @discardableResult
    func paste(_ text: String, submit: Bool) -> Bool {
        guard terminal.paste(text: text) else { return false }
        if submit { terminal.sendKey(.enter) }
        return true
    }

    func focus() {
        window?.makeFirstResponder(terminal)
    }

    fileprivate func attached(_ surface: TerminalSurface?) {
        self.surface = surface
    }

    fileprivate func titleChanged(_ title: String) {
        onTitle?(title)
    }

    // MARK: TileContent

    private var isLive = true
    private var occlusionObserver: NSObjectProtocol?

    func setLive(_ live: Bool) {
        isLive = live
        updateSurfaceVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        occlusionObserver.map(NotificationCenter.default.removeObserver)
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSurfaceVisibility() }
            }
        }
        updateSurfaceVisibility()
    }

    /// Ghostty renders every display-link tick while output streams, even into a window nobody
    /// sees (another Space, covered, minimized): ~18% CPU for one busy terminal. Draw only while
    /// the tile is live and its window visible; the session keeps running either way.
    private func updateSurfaceVisibility() {
        terminal.setSurfaceVisible(isLive && window?.occlusionState.contains(.visible) == true)
    }

    /// Ghostty draws through Metal, which `cacheDisplay` can't capture, so snapshots (LOD cards,
    /// `view.snapshot`, `object.get --as image`) render the tail of the zmx session's text instead.
    func snapshot() -> NSImage? {
        guard let rows = snapshotRows else { return nil }
        return Self.history(session: sessionName, lines: rows).map { render($0.text) }
    }

    /// Zooming out flips every terminal at once; each `zmx history` takes tens of milliseconds,
    /// so cards read it on GCD instead of stalling the main thread once per terminal.
    func cardSnapshot(_ deliver: @escaping @MainActor (NSImage?) -> Void) {
        guard let rows = snapshotRows else { return deliver(nil) }
        let session = sessionName
        DispatchQueue.global(qos: .utility).async {
            let tail = Self.history(session: session, lines: rows)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in deliver(tail.flatMap { self?.render($0.text) }) }
            }
        }
    }

    private static let snapshotFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let snapshotLineHeight = ceil(snapshotFont.ascender - snapshotFont.descender + snapshotFont.leading) + 2

    private var snapshotRows: Int? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return max(1, Int((bounds.height - 12) / Self.snapshotLineHeight))
    }

    private func render(_ text: String) -> NSImage {
        let visible = text.split(separator: "\n", omittingEmptySubsequences: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.snapshotFont, .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        let lineHeight = Self.snapshotLineHeight
        return NSImage(size: bounds.size, flipped: true) { rect in
            NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1).setFill()
            rect.fill()
            for (index, line) in visible.enumerated() {
                NSString(string: String(line)).draw(at: NSPoint(x: 6, y: 6 + CGFloat(index) * lineHeight), withAttributes: attributes)
            }
            return true
        }
    }

    private var snapshotView: NSImageView?

    /// Temporarily covers the Metal surface with its text snapshot so `cacheDisplay` can capture it.
    func showSnapshot(_ show: Bool) {
        snapshotView?.removeFromSuperview()
        snapshotView = nil
        terminal.isHidden = false
        guard show, let image = snapshot() else { return }
        let view = NSImageView(frame: bounds)
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        addSubview(view)
        snapshotView = view
        terminal.isHidden = true
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        if let text = surface?.readSelection(), !text.isEmpty {
            return .terminal(object: objectID, text: text)
        }
        return .object(objectID)
    }

    func outline(for target: MentionTarget) -> NSRect? { bounds }

    var takesKeyboardFocus: Bool { true }

    func update(_ object: CanvasObject) {}
}

/// Retained delegate for the terminal view (its delegate reference is weak).
@MainActor
private final class TerminalEvents: NSObject, TerminalSurfaceTitleDelegate, TerminalSurfaceLifecycleDelegate {
    weak var tile: TerminalTile?

    func terminalDidChangeTitle(_ title: String) {
        tile?.titleChanged(title)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        tile?.attached(surface)
    }

    func terminalDidDetachSurface() {
        tile?.attached(nil)
    }
}
