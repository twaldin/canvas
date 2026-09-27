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
        terminal = TerminalView(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
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
            // Shell integration (extensions/shell): after the user's startup files, Canvas's bin
            // goes back to the front of PATH so its claude/codex wrappers aren't shadowed.
            let shell = resources.appendingPathComponent("extensions/shell")
            env["ZDOTDIR"] = shell.appendingPathComponent("zsh").path
            if let zdotdir = inherited["ZDOTDIR"] { env["CANVAS_ZSH_ZDOTDIR"] = zdotdir }
            let bash = ". " + quote([shell.appendingPathComponent("bash/canvas.bash").path])
            env["PROMPT_COMMAND"] = inherited["PROMPT_COMMAND"].map { "\(bash); \($0)" } ?? bash
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
        // `canvas.home` names the owning instance: board copies in another home (replicas, dev
        // instances) carry the same board and tile ids, so ids alone can't tell whose session it is.
        let labels = "canvas.board=\(board.id) canvas.tile=\(object.id) canvas.home=\(homeLabel)"
        let attach = ["/usr/bin/env"] + strip + [zmx, "attach", "--labels", labels, session] + start
        let refusal = #"printf '\nThis terminal session (%s) belongs to another Canvas instance (%s).\nNot attaching: this copy of the board can neither type into it nor end it.\n' "$2" "$owner"; exec sleep 2147483647"#
        return quote(["/bin/sh", "-c", ownerGuard(refusal: refusal) + "shift 3\nexec \"$@\"", "canvas-attach", zmx, session, homeLabel] + attach)
    }

    /// A prologue for `sh -c` with $1 = zmx, $2 = session name, $3 = this instance's home label:
    /// runs `refusal` when the session exists labelled for another home. A board copied into
    /// another home has the same tile ids, and `zmx attach --labels` relabels an existing session,
    /// so without this a copy took over the original's sessions and its cleanup ended them.
    /// Sessions without a home label (older ones) pass.
    static func ownerGuard(refusal: String) -> String {
        #"""
        owner=$("$1" list 2>/dev/null | awk -F'\t' -v n="name=$2" '{ s = $1; sub(/^[ *]+/, "", s) } s == n { for (i = 2; i <= NF; i++) if (index($i, "canvas.home=") == 1) print substr($i, 13) }')
        if [ -n "$owner" ] && [ "$owner" != "$3" ]; then \#(refusal); fi

        """#
    }

    /// The support directory as a zmx label value, which allows only `[A-Za-z0-9._-]`: every other
    /// UTF-8 byte becomes `_` (what `tr -c` does in scripts/dev.sh).
    static let homeLabel: String = {
        let legal = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
        return String(decoding: AppPaths.support.path.utf8.map { legal.contains($0) ? $0 : UInt8(ascii: "_") }, as: UTF8.self)
    }()

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

    /// Ends a deleted terminal's persistent session (`Board.onTerminalsEnded`: every delete path,
    /// UI, API, batch, undo/redo). Never another instance's session (`ownerGuard`).
    static func killSession(tile: ObjectID) {
        guard let zmx = AppPaths.zmx else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ownerGuard(refusal: "exit 0") + "exec \"$1\" kill \"$2\"", "canvas-kill", zmx, sessionName(tile), homeLabel]
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

    /// Below this a terminal is a smudge, and Ghostty at ~0.1 zoom held ~235 MB of GPU memory
    /// that a card doesn't.
    var liveZoom: CGFloat { 0.15 }

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

    /// The grid Ghostty reports for this surface, in points; nil until it first lays out.
    private var grid: TerminalRender.Grid?

    fileprivate func resized(_ metrics: TerminalGridMetrics) {
        let scale = window?.backingScaleFactor ?? 2
        guard metrics.columns > 0, metrics.rows > 0, metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return }
        grid = TerminalRender.Grid(columns: Int(metrics.columns), rows: Int(metrics.rows),
                                   cell: CGSize(width: CGFloat(metrics.cellWidthPixels) / scale, height: CGFloat(metrics.cellHeightPixels) / scale))
    }

    /// The session's styled screen text: the last `rows` lines of `zmx history --vt` and the
    /// row the cursor ends on. Blocks until zmx exits; nil when zmx or the session is missing.
    nonisolated static func styledHistory(session: String, rows: Int) -> (lines: [TerminalLine], cursorRow: Int?)? {
        guard let zmx = AppPaths.zmx else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = ["history", session, "--vt"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        var tail = TerminalStyledTail(limit: rows)
        let reader = output.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
            tail.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let lines = tail.finish()
        return (lines, tail.cursorRow)
    }

    /// Ghostty draws through Metal, which `cacheDisplay` can't capture, so renders, cards, and
    /// `view.snapshot` covers draw the session's styled text on the tile's grid instead.
    func render(_ request: TileRenderRequest) async -> TileRender {
        let grid = TerminalRender.grid(for: request.size, known: grid)
        let session = sessionName
        let rows = grid.rows
        guard let history = await offPool(qos: .userInitiated, { Self.styledHistory(session: session, rows: rows) }) else {
            return .placeholder(request, "terminal session \(session) is not running")
        }
        let screen = TerminalRender.screen(history.lines, cursorRow: history.cursorRow, rows: rows)
        let image = request.image { bounds in TerminalRender.draw(screen, grid: grid, in: bounds, appearance: request.appearance) }
        return TileRender(image: image, contentSize: request.size, state: image == nil ? .failed : .rendered)
    }

    private var snapshotView: NSImageView?

    /// Temporarily covers the Metal surface with its text so `cacheDisplay` can capture it
    /// (synchronous: `view.snapshot` renders in one pass).
    func showSnapshot(_ show: Bool) {
        snapshotView?.removeFromSuperview()
        snapshotView = nil
        terminal.isHidden = false
        let grid = TerminalRender.grid(for: bounds.size, known: grid)
        guard show, let history = Self.styledHistory(session: sessionName, rows: grid.rows) else { return }
        let screen = TerminalRender.screen(history.lines, cursorRow: history.cursorRow, rows: grid.rows)
        let request = TileRenderRequest(size: bounds.size, scale: window?.backingScaleFactor ?? 2, full: false, appearance: effectiveAppearance)
        let view = NSImageView(frame: bounds)
        view.image = request.image { rect in TerminalRender.draw(screen, grid: grid, in: rect, appearance: request.appearance) }
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
private final class TerminalEvents: NSObject, TerminalSurfaceTitleDelegate, TerminalSurfaceLifecycleDelegate, TerminalSurfaceGridResizeDelegate {
    weak var tile: TerminalTile?

    func terminalDidResize(_ size: TerminalGridMetrics) {
        tile?.resized(size)
    }

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
