import AppKit
import CanvasCore
import GhosttyKit
import GhosttyTerminal

/// A Ghostty surface running `zmx attach <session>`: the agent/shell survives app quit, crash,
/// and rebuild; reattaching restores the screen. After a reboot, a recorded agent session resumes.
@MainActor
final class TerminalTile: NSView, TileContent {
    let objectID: ObjectID
    let sessionName: String
    let terminal: CanvasTerminalView
    private let board: Board
    private var surface: TerminalSurface?
    private let handler = TerminalEvents()
    private let underline = TerminalLinkUnderline()
    /// The header text changed: the name (`props.name`, else the foreground program) and the
    /// live title the program set (`TerminalName.label`).
    var onTitle: ((String) -> Void)?
    /// A ⌘-clicked reference opened this code tile (`created`) or re-aimed or found it there;
    /// `source` is the reference's rect in window coordinates.
    var onOpenedCode: ((ObjectID, _ created: Bool, _ source: NSRect) -> Void)?

    init(object: CanvasObject, board: Board) {
        objectID = object.id
        sessionName = Self.sessionName(object.id)
        self.board = board
        terminal = CanvasTerminalView(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        super.init(frame: terminal.frame)
        terminal.autoresizingMask = [.width, .height]
        let environment = Self.environment(tile: object.id, board: board)
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: object.props["cwd"]?.string ?? board.root.path,
            envVars: environment,
            command: Self.command(session: sessionName, object: object, board: board, keep: Set(environment.keys))
        )
        terminal.controller = TerminalConfig.shared.controller
        handler.tile = self
        terminal.delegate = handler
        terminal.linkAt = { [weak self] point in self?.link(at: point) }
        terminal.onHover = { [weak self] hit in self?.showUnderline(hit) }
        terminal.onOpen = { [weak self] hit, newTile in self?.open(hit, newTile: newTile) }
        terminal.hasScrollback = { [weak self] in self?.scrollbar.map { $0.total > $0.len } ?? false }
        addSubview(terminal)
        underline.frame = bounds
        underline.autoresizingMask = [.width, .height]
        underline.isHidden = true
        addSubview(underline)
        name = object.props["name"]?.string
        TerminalProgramWatch.shared.add(self)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Launch

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
    /// Everything else the app inherited is unset (`LoginSession.strippedForTile`): the shell starts
    /// like a fresh login session and the user's startup files set their own variables.
    static func command(session: String, object: CanvasObject, board: Board, keep: Set<String>) -> String {
        let shell = AppPaths.userShell
        let start = initialCommand(object).map { [shell, "-l", "-c", "\($0); exec \(quote([shell])) -l"] } ?? [shell, "-l"]
        guard let zmx = AppPaths.zmx else { return quote(start) }
        let strip = LoginSession.strippedForTile(ProcessInfo.processInfo.environment, keep: keep).flatMap { ["-u", $0] }
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
    /// recorded agent session (`AgentResume`: omp, claude, codex, gemini, opencode); otherwise the tile's initial `command`.
    static func initialCommand(_ object: CanvasObject) -> String? {
        if let kind = object.props["agent"]?["kind"]?.string, let sessionId = object.props["agent"]?["sessionId"]?.string,
           let resume = AgentResume.argv(kind: kind, sessionId: sessionId) {
            return quote(resume)
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
    nonisolated static func history(session: String, lines limit: Int) -> TerminalTail.Tail? {
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

    /// Paste text honoring bracketed-paste mode.
    @discardableResult
    func paste(_ text: String) -> Bool {
        terminal.paste(text: text)
    }

    /// How long a submitted prompt waits between its paste and Enter. TUIs take an Enter that
    /// follows the previous input within a few milliseconds as part of a paste (Gemini CLI turns
    /// one within 30 ms into Shift+Enter, a newline), so the prompt would sit unsent.
    static let submitDelay: Duration = .milliseconds(80)

    /// Pastes `text` and presses Enter once the paste has landed (`submitDelay`).
    func submit(_ text: String) async -> Bool {
        guard terminal.paste(text: text) else { return false }
        try? await Task.sleep(for: Self.submitDelay)
        terminal.sendKey(.enter)
        return true
    }

    func focus() {
        window?.makeFirstResponder(terminal)
    }

    func enterKeyboard() -> Bool {
        focus()
        return true
    }

    /// Ghostty starts a surface focused, and libghostty-spm tells it otherwise only when first
    /// responder or key window changes. Until then a terminal nobody had focused kept Ghostty's
    /// focused-surface timers (cursor blink, termios polling) running once it had been shown,
    /// minimized or not: ~12 wakeups/s per terminal.
    fileprivate func attached(_ surface: TerminalSurface?) {
        self.surface = surface
        guard let handle = surface?.handle else { return }
        ghostty_surface_set_focus(handle, window?.isKeyWindow == true && window?.firstResponder === terminal)
    }

    fileprivate func titleChanged(_ title: String) {
        oscTitle = title
        refreshProgram()
        publishLabel()
    }

    // MARK: Name

    /// The user's or an agent's name for this terminal (`props.name`).
    private var name: String?
    /// The title the program in the terminal set (OSC 0/2), as it reports it.
    private(set) var oscTitle: String?
    /// What runs in the foreground (`TerminalName.program`: `gemini`, `cargo test`); nil at the prompt.
    private(set) var program: String?
    /// The session's shell (`ForegroundProgram.shellPid`), looked up once.
    private var shell: pid_t?
    private var shellLookup: Date?

    /// Reads the foreground program again (a few syscalls once the session's shell is known).
    func refreshProgram() {
        guard let shell else { return findShell() }
        let state = ForegroundProgram.state(shell: shell)
        if state == .gone { self.shell = nil }
        let program: String? = switch state {
        case .running(let argv): TerminalName.program(argv: argv)
        case .gone, .prompt: nil
        }
        guard program != self.program else { return }
        self.program = program
        publishLabel()
    }

    /// Looks up the session's shell off the main actor, at most every few seconds (a session
    /// that doesn't exist yet appears once zmx has started it).
    private func findShell() {
        if let shellLookup, Date().timeIntervalSince(shellLookup) < 5 { return }
        shellLookup = Date()
        let session = sessionName
        Task { [weak self] in
            let pid = await offPool { ForegroundProgram.shellPid(session: session) }
            guard let self, let pid else { return }
            self.shell = pid
            self.refreshProgram()
        }
    }

    private func publishLabel() {
        guard let object = board.objects[objectID] else { return }
        onTitle?(TerminalName.label(name: name ?? program, title: oscTitle) ?? TileFrameView.title(for: object))
    }

    // MARK: Notices

    /// The user is looking at this terminal: it has keyboard focus in the active app's key window.
    private var isWatched: Bool {
        guard let window, NSApp.isActive, window.isKeyWindow else { return false }
        return window.firstResponder === terminal
    }

    /// A program asked for the user (OSC 9 / OSC 777 `notify`, or BEL): an attention marker on
    /// this terminal, unless the user is already looking at it.
    fileprivate func notice(_ message: String, bell: Bool) {
        guard !isWatched else { return }
        if board.raiseTerminalNotice(objectID, message: message, bell: bell) {
            NSLog("Canvas: terminal %@ %@: %@", objectID, bell ? "rang the bell" : "sent a notification", message)
        }
    }

    // MARK: Exit

    /// Ghostty closed the surface: its process (`zmx attach`) exited, and the user pressed a key
    /// on "Process exited. Press any key to close the terminal" (or it exited cleanly). The
    /// session ended with it, so the tile goes the normal delete path without asking: there is
    /// nothing left to kill. A detached client (the session still runs) reattaches instead.
    /// `processAlive` is Ghostty's own close request (its ⌘W binding): not an exit, ignored here.
    fileprivate func surfaceClosed(processAlive: Bool) {
        guard !processAlive else { return }
        let session = sessionName
        Task { [weak self] in
            let running = await offPool { Self.sessionExists(session) }
            guard let self, self.board.objects[self.objectID] != nil else { return }
            if running {
                NSLog("Canvas: terminal %@ detached from a running session; reattaching", self.objectID)
                let controller = self.terminal.controller
                self.terminal.controller = nil
                self.terminal.controller = controller
            } else {
                NSLog("Canvas: terminal %@ exited; closing it", self.objectID)
                self.board.transaction { try? self.board.delete(self.objectID) }
            }
        }
    }

    /// Whether zmx still has `session`. Blocks until zmx exits; false without zmx.
    nonisolated static func sessionExists(_ session: String) -> Bool {
        guard let zmx = AppPaths.zmx else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = ["list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).contains { line in
            let name = line.split(separator: "\t").first?.drop { $0 == " " || $0 == "*" } ?? ""
            return name == "name=\(session)"
        }
    }

    // MARK: References

    /// The directory the shell last reported (OSC 7), which relative references resolve against
    /// first, and where an agent started in it works (`Board.reportedDirectory`).
    fileprivate(set) var reportedCwd: String?

    /// The `path:line` reference drawn at `point` (terminal view coordinates) that names an
    /// existing file (`TerminalReferences.hit`, which follows it onto neighbouring rows):
    /// relative to the reported cwd, then `props.cwd`, then the board root, then by name among
    /// the board root's files (`BoardFiles`), nearest the cwd.
    private func link(at point: NSPoint) -> TerminalReferences.Hit? {
        guard let surface, let grid else { return nil }
        let padding = TerminalConfig.shared.style(for: effectiveAppearance).padding
        let fromTop = terminal.bounds.height - point.y
        let column = Int(floor((point.x - padding.width) / grid.cell.width))
        let row = Int(floor((fromTop - padding.height) / grid.cell.height))
        guard (0..<grid.columns).contains(column), (0..<grid.rows).contains(row) else { return nil }
        let cwd = board.objects[objectID]?.props["cwd"]?.string
        let directories = [reportedCwd, cwd, board.root.path].compactMap { $0 }
        let files = BoardFiles.of(board.root)
        let listed = (root: files.root.path, files: files.current())
        let near = reportedCwd ?? cwd ?? board.root.path
        return TerminalReferences.hit(row: row, column: column, columns: grid.columns,
                                      read: { $0 < grid.rows ? surface.viewportRow($0, columns: grid.columns) : nil },
                                      resolve: { TerminalReferences.resolve($0, directories: directories, home: NSHomeDirectory(), isFile: TerminalReferences.isFile, listed: listed, near: near) })
    }

    /// The cells `runs` cover in the underline's (flipped) coordinates, `height` tall at the
    /// bottom of each cell (the whole cell when nil).
    private func rects(_ runs: [TerminalTextRows.Run], grid: TerminalRender.Grid, height: CGFloat? = nil) -> [NSRect] {
        let padding = TerminalConfig.shared.style(for: effectiveAppearance).padding
        return runs.map { run in
            let height = height ?? grid.cell.height
            return NSRect(x: padding.width + CGFloat(run.column) * grid.cell.width,
                          y: padding.height + CGFloat(run.row + 1) * grid.cell.height - height,
                          width: CGFloat(run.width) * grid.cell.width, height: height)
        }
    }

    private func showUnderline(_ hit: TerminalReferences.Hit?) {
        guard let hit, let grid else {
            underline.isHidden = true
            return
        }
        underline.color = TerminalConfig.shared.style(for: effectiveAppearance).foreground
        underline.rects = rects(hit.runs, grid: grid, height: max(1, (grid.cell.height / 14).rounded()))
        underline.isHidden = false
    }

    private func open(_ hit: TerminalReferences.Hit, newTile: Bool) {
        let opened = board.openCode(path: hit.file, lines: hit.lines, beside: objectID, newTile: newTile)
        NSLog("Canvas: terminal %@ opened %@:%d-%d as %@ (%@)", objectID, hit.file, hit.lines.start, hit.lines.end, opened.id,
              opened.created ? (newTile ? "new tile" : "new preview") : "re-aimed or existing")
        let source = grid.map { rects(hit.runs, grid: $0).reduce(NSRect.null) { $0.union($1) } } ?? .null
        onOpenedCode?(opened.id, opened.created, source.isNull ? .null : underline.convert(source, to: nil))
    }

    // MARK: Scrollback

    /// Ghostty's scrollbar (rows in total, the viewport's offset and rows); nil until reported.
    fileprivate var scrollbar: TerminalScrollbar?

    // MARK: TileContent

    private var isLive = true
    private var windowObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func setLive(_ live: Bool) {
        isLive = live
        updateSurfaceVisibility()
    }

    /// Below this a terminal is a smudge, and Ghostty at ~0.1 zoom held ~235 MB of GPU memory
    /// that a card doesn't.
    var liveZoom: CGFloat { 0.15 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { observer.center.removeObserver(observer.token) }
        windowObservers = []
        if let window {
            let changed: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.windowVisibilityChanged() }
            }
            let app = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
            let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            windowObservers = names.map { (app, app.addObserver(forName: $0, object: window, queue: .main, using: changed)) }
                + [NSApplication.didHideNotification, NSApplication.didUnhideNotification].map { (app, app.addObserver(forName: $0, object: NSApp, queue: .main, using: changed)) }
                + [(workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: changed))]
        }
        updateSurfaceVisibility()
    }

    /// AppKit posts these before `occlusionState` settles (`didMiniaturize` arrives with the
    /// window still occlusion-visible, `didDeminiaturize` with it still occluded), so look again
    /// on the next main-loop turn.
    private func windowVisibilityChanged() {
        updateSurfaceVisibility()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateSurfaceVisibility() }
        }
    }

    /// Ghostty renders every display-link tick while output streams, even into a window nobody
    /// sees: ~18% CPU for one busy terminal. Draw only while the tile is live and its window
    /// shown (not minimized, covered, on another Space, in a background tab, or the app hidden);
    /// the session keeps running either way, and a surface shown again draws the current screen.
    private func updateSurfaceVisibility() {
        let shown = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        terminal.setSurfaceVisible(isLive && shown)
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
        let grid = TerminalRender.grid(for: request.size, known: grid, style: TerminalConfig.shared.style(for: request.appearance))
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
    /// (synchronous: `view.snapshot` renders in one pass). The surface stays unhidden: hiding it
    /// would take its keyboard focus, and the program would see a focus-out and focus-in.
    func showSnapshot(_ show: Bool) {
        snapshotView?.removeFromSuperview()
        snapshotView = nil
        let grid = TerminalRender.grid(for: bounds.size, known: grid, style: TerminalConfig.shared.style(for: effectiveAppearance))
        guard show, let history = Self.styledHistory(session: sessionName, rows: grid.rows) else { return }
        let screen = TerminalRender.screen(history.lines, cursorRow: history.cursorRow, rows: grid.rows)
        let request = TileRenderRequest(size: bounds.size, scale: window?.backingScaleFactor ?? 2, full: false, appearance: effectiveAppearance)
        let view = NSImageView(frame: bounds)
        view.image = request.image { rect in TerminalRender.draw(screen, grid: grid, in: rect, appearance: request.appearance) }
        view.imageScaling = .scaleAxesIndependently
        addSubview(view)
        snapshotView = view
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        if let text = surface?.readSelection(), !text.isEmpty {
            return .terminal(object: objectID, text: text)
        }
        return .object(objectID)
    }

    func outline(for target: MentionTarget) -> NSRect? { bounds }

    var takesKeyboardFocus: Bool { true }

    func update(_ object: CanvasObject) {
        let name = object.props["name"]?.string
        guard name != self.name else { return }
        self.name = name
        publishLabel()
    }
}

/// Retained delegate for the terminal view (its delegate reference is weak).
@MainActor
private final class TerminalEvents: NSObject, TerminalSurfaceTitleDelegate, TerminalSurfaceLifecycleDelegate, TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceBellDelegate, TerminalSurfaceDesktopNotificationDelegate, TerminalSurfacePwdDelegate, TerminalSurfaceCloseDelegate,
    TerminalSurfaceScrollbarDelegate {
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

    func terminalDidRingBell() {
        tile?.notice("Bell", bell: true)
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        tile?.notice(Board.noticeMessage(title: title, body: body), bell: false)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        tile?.reportedCwd = path.isEmpty ? nil : path
        // The shell reports its directory at each prompt: whatever ran has finished.
        tile?.refreshProgram()
    }

    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        tile?.scrollbar = scrollbar
    }

    func terminalDidClose(processAlive: Bool) {
        tile?.surfaceClosed(processAlive: processAlive)
    }
}
