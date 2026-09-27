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
    /// The last command's status for the header (`TerminalCommand.status`: `exit 1 · 42 s`), nil
    /// after a quick success; `detail` says what ran, for its tooltip.
    var onStatus: ((_ status: String?, _ failed: Bool, _ detail: String?) -> Void)?
    /// A ⌘-clicked reference opened this code tile (`created`) or re-aimed or found it there;
    /// `source` is the reference's rect in window coordinates.
    var onOpenedCode: ((CodeOpened, _ source: NSRect) -> Void)?

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
        terminal.onMissedLink = { [weak self] point, newTile in self?.retryLink(at: point, newTile: newTile) }
        // AppKit makes the view first responder only after `becomeFirstResponder` returns.
        terminal.onFocusChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateSurfaceFocus() } }
        }
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
            // Ghostty's own shell integration (prompt marks), which the scripts above load.
            if let integration = TerminalConfig.shared.shellIntegration { env["CANVAS_GHOSTTY_INTEGRATION"] = integration }
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
    /// `columns`: the terminal's width, so rows it soft-wrapped read as one line.
    nonisolated static func history(session: String, lines limit: Int, columns: Int? = nil) -> TerminalTail.Tail? {
        guard let zmx = AppPaths.zmx else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = ["history", session]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Drain while zmx writes: it blocks once the pipe buffer fills, so waiting first would deadlock.
        var tail = TerminalTail(limit: limit, columns: columns)
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

    /// Pastes `text` and presses Enter once the paste has landed (`submitDelay`). Into a shell at
    /// its prompt a one-line command is typed instead (`ShellTyping`), so no bracketed-paste
    /// marker can reach its line editor in pieces.
    func submit(_ text: String) async -> Bool {
        refreshProgram()
        if shell != nil, program == nil, let typing = ShellTyping.action(text) {
            guard terminal.performBindingAction(typing) else { return false }
        } else {
            guard terminal.paste(text: text) else { return false }
        }
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
        updateSurfaceFocus()
    }

    /// Ghostty's focus, as a terminal app has it: the terminal has keyboard focus in the key
    /// window of the active app, and the window isn't minimized. libghostty-spm sets it on first
    /// responder and key-window changes only, so a terminal focused while the app was inactive
    /// (an API focus, a window that never became key) or whose window was minimized kept
    /// Ghostty's focused timers (cursor blink, termios polling: 12–18 wakeups/s) running.
    func updateSurfaceFocus() {
        guard let handle = surface?.handle else { return }
        let focused = window.map { NSApp.isActive && $0.isKeyWindow && !$0.isMiniaturized && $0.firstResponder === terminal } ?? false
        ghostty_surface_set_focus(handle, focused)
    }

    fileprivate func titleChanged(_ title: String) {
        oscTitle = title
        commands.title(title, at: Date(), promptTitle: TerminalCommandTracker.promptTitle(cwd: reportedCwd, home: NSHomeDirectory()))
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
    /// The session's shell (`ForegroundProgram.shellPid`), looked up once, and its name (`zsh`).
    private var shell: pid_t?
    private var shellName: String?
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
        commands.running(program: program)
        guard program != self.program else { return }
        self.program = program
        publishLabel()
    }

    /// Inside tmux, what its active pane runs (`ForegroundProgram.tmuxPane`); nil otherwise.
    func tmuxPane() async -> String? {
        guard let shell else { return nil }
        return await offPool { ForegroundProgram.tmuxPane(shell: shell) }
    }

    /// What closing this terminal ends, for the close sheet (`SessionProcesses`); nil until the
    /// session's shell is known.
    func sessionProcesses() -> SessionProcesses? {
        shell.flatMap { ForegroundProgram.session(shell: $0) }
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
            self.shellName = ForegroundProgram.name(pid)
            self.refreshProgram()
        }
    }

    private func publishLabel() {
        guard let object = board.objects[objectID] else { return }
        onTitle?(label ?? TileFrameView.title(for: object))
    }

    /// What the header calls this terminal: its name, else the program running in it, with the
    /// title that program set (`TerminalName.label`); nil when it has none of them.
    var label: String? {
        TerminalName.label(name: name ?? program, title: oscTitle?.trimmingCharacters(in: .whitespaces))
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

    /// BEL: a marker naming what rang it (`TerminalCommand.bellMessage`).
    fileprivate func bell() {
        refreshProgram()
        notice(TerminalCommand.bellMessage(program: program, shell: shellName, last: lastCommand, at: Date()), bell: true)
    }

    // MARK: Commands

    /// What the shell is running, from the titles Ghostty's shell integration sets.
    fileprivate var commands = TerminalCommandTracker()
    /// The last command the shell finished (Ghostty's shell integration: OSC 133 D), and when.
    private(set) var lastCommand: (command: TerminalCommand, finishedAt: Date)?

    /// A command finished: the header shows its exit status or duration when it failed or ran
    /// long, and one that ran `noticeAfterMs` or more raises a marker (the bell's rules: not
    /// while the user looks at the terminal, never for an agent reporting a lifecycle). A mark
    /// while a program holds the foreground, or while the tile's agent reports a lifecycle, is
    /// that program's, not a shell command (`TerminalCommandTracker.finished`).
    fileprivate func commandFinished(exit: Int?, durationNanos: UInt64) {
        var atPrompt = true
        if let shell, case .running = ForegroundProgram.state(shell: shell) { atPrompt = false }
        let lifecycle = board.objects[objectID]?.props["lifecycle"]?["state"]?.string
        let reporting = lifecycle != nil && lifecycle != LifecycleState.unknown.rawValue
        guard let command = commands.finished(exit: exit, durationNanos: durationNanos, at: Date(), shellAtPrompt: atPrompt, agentReporting: reporting) else { return }
        lastCommand = (command, Date())
        let detail = ([command.command ?? "The last command"] + [command.exit.map { "exit \($0)" }, command.durationMs.map(TerminalCommand.duration)].compactMap { $0 })
            .joined(separator: " · ")
        onStatus?(command.status, (command.exit ?? 0) != 0, detail)
        guard (command.durationMs ?? 0) >= TerminalCommand.noticeAfterMs else { return }
        notice(command.noticeMessage, bell: false)
    }

    // MARK: Mentions

    /// While Hyper is held: the selection, else the whole terminal. A click resolves more
    /// (`resolveMention`), but finding a command's block takes Ghostty a click, too much for hover.
    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        if let text = surface?.readSelection(), !text.isEmpty {
            return .terminal(object: objectID, text: text)
        }
        return .object(objectID)
    }

    /// A Hyper-click: the selection; else, inside a command's output that Ghostty's shell
    /// integration marked, that command's block; else the screen rows around the click. Outside
    /// the text (the title bar, the padding): the whole terminal.
    func resolveMention(at point: NSPoint) async -> MentionTarget? {
        if let text = surface?.readSelection(), !text.isEmpty {
            return .terminal(object: objectID, text: text)
        }
        guard let surface, let grid, let cell = cell(at: point) else { return .object(objectID) }
        if let block = commandBlock(row: cell.row, column: cell.column) {
            return .terminal(object: objectID, text: block.output, part: .command, command: block.command)
        }
        let from = max(0, cell.row - Self.rowsBefore), to = min(grid.rows - 1, cell.row + Self.rowsAfter)
        let rows = (from...to).map { surface.viewportRow($0, columns: grid.columns) ?? "" }
        let lines = TerminalExcerpt.around(rows, index: cell.row - from, before: Self.rowsBefore, after: Self.rowsAfter)
        return .terminal(object: objectID, text: lines.joined(separator: "\n"), part: .rows)
    }

    /// Edit › Mention: the selection; else, with the keyboard here and the shell at its prompt,
    /// the last command's block (what ran, its output); else the whole terminal.
    func keyboardMention(hasKeyboard: Bool) async -> MentionTarget? {
        if let text = surface?.readSelection(), !text.isEmpty { return .terminal(object: objectID, text: text) }
        refreshProgram()
        guard hasKeyboard, shell != nil, program == nil, let block = try? lastBlock(), !block.output.isEmpty else { return nil }
        return .terminal(object: objectID, text: block.output, part: .command, command: block.command)
    }

    /// The screen rows a Hyper-click outside a command's output mentions: an error's context is
    /// mostly above it.
    static let rowsBefore = 8
    static let rowsAfter = 3

    /// The viewport cell under `point` (this view's coordinates); nil in the padding.
    private func cell(at point: NSPoint) -> (row: Int, column: Int)? {
        guard let grid else { return nil }
        let padding = TerminalConfig.shared.style(for: effectiveAppearance).padding
        let fromTop = terminal.bounds.height - point.y
        let column = Int(floor((point.x - padding.width) / grid.cell.width))
        let row = Int(floor((fromTop - padding.height) / grid.cell.height))
        guard (0..<grid.columns).contains(column), (0..<grid.rows).contains(row) else { return nil }
        return (row, column)
    }

    /// The command block whose output covers viewport cell (`row`, `column`): its output, and
    /// what ran (`TerminalBlocks.command`: the shell's last command with exit status and
    /// duration when this is its block, else the prompt row above the output). Nil without
    /// Ghostty's prompt marks there.
    private func commandBlock(row: Int, column: Int) -> (output: String, command: TerminalCommand?)? {
        guard let surface, let grid, let output = selectOutput(row: row, column: column) else { return nil }
        func text(_ row: Int) -> String { (surface.viewportRow(row, columns: grid.columns) ?? "").trimmingCharacters(in: .whitespaces) }
        let promptRow = output.top > 0 ? text(output.top - 1) : nil
        // Where the output ends on screen: the row just above the prompt showing its last line.
        let last = output.text.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let cursor = cursorRow
        let end = cursor.flatMap { cursor in
            stride(from: cursor - 1, through: max(0, cursor - TerminalBlocks.promptRows - 1), by: -1).first { !text($0).isEmpty && last.hasSuffix(text($0)) }
        } ?? output.top + TerminalBlocks.rows(of: output.text, columns: grid.columns) - 1
        refreshProgram()
        let command = TerminalBlocks.command(promptRow: promptRow, outputEnd: end, cursorRow: cursor,
                                             atPrompt: shell != nil && program == nil, last: lastCommand?.command)
        guard command?.exit != nil || command?.durationMs != nil else {
            // Starting at the very top of everything the terminal holds, with no prompt above:
            // text from before Canvas reattached to the session, which carries no marks.
            if output.top == 0, (scrollbar?.offset ?? 0) == 0 { return nil }
            return (output.text, command)
        }
        return (TerminalBlocks.output(output.text, after: command?.command), command)
    }

    /// The output of the command whose block covers viewport cell (`row`, `column`), as Ghostty
    /// selects it on a ⌘-triple-click (Ghostty's semantic prompts: the output between the
    /// command's line and the next prompt), and the viewport row it starts on. Ghostty's C API
    /// has no call for the block itself, so this is that triple click, with the selection
    /// cleared after it by a click on the top-left cell (above any prompt, so it never moves
    /// the cursor). Nil when a program owns the mouse (a TUI), the user has a selection (it
    /// would be lost), or the cell isn't command output.
    private func selectOutput(row: Int, column: Int) -> (text: String, top: Int)? {
        guard let handle = surface?.handle, let grid, !ghostty_surface_mouse_captured(handle), !ghostty_surface_has_selection(handle) else { return nil }
        // The current prompt at the top of the screen: that click would land on it.
        if let cursorRow, cursorRow < TerminalBlocks.promptRows { return nil }
        let padding = TerminalConfig.shared.style(for: effectiveAppearance).padding
        let none = GHOSTTY_MODS_NONE, command = GHOSTTY_MODS_SUPER
        ghostty_surface_mouse_pos(handle, Double(padding.width + (CGFloat(column) + 0.5) * grid.cell.width),
                                  Double(padding.height + (CGFloat(row) + 0.5) * grid.cell.height), none)
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, command)
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, command)
        let word = readSelection(handle)
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, command)
        let output = readSelection(handle)
        ghostty_surface_mouse_pos(handle, Double(padding.width + grid.cell.width / 2), Double(padding.height + grid.cell.height / 2), none)
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, none)
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, none)
        ghostty_surface_mouse_pos(handle, -1, -1, none)
        if ghostty_surface_has_selection(handle) { NSLog("Canvas: terminal %@ kept a selection after reading a command block", objectID) }
        guard let output, !output.text.isEmpty, output.text != word?.text else { return nil }
        // `tl_px_y`: the first row's baseline, in points from the top.
        let top = Int(floor((CGFloat(output.y) - padding.height) / grid.cell.height))
        return (output.text, max(0, top))
    }

    private func readSelection(_ handle: ghostty_surface_t) -> (text: String, y: Double)? {
        var out = ghostty_text_s()
        guard ghostty_surface_read_selection(handle, &out) else { return nil }
        defer { ghostty_surface_free_text(handle, &out) }
        guard let text = out.text, out.text_len > 0 else { return nil }
        return (String(decoding: UnsafeRawBufferPointer(start: text, count: Int(out.text_len)), as: UTF8.self), out.tl_px_y)
    }

    /// The viewport row the cursor is on; nil when it's out of view or unknown. Ghostty gives
    /// the cursor's cell by its bottom, in points from the top.
    private var cursorRow: Int? {
        guard let handle = surface?.handle, let grid else { return nil }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(handle, &x, &y, &width, &height)
        let padding = TerminalConfig.shared.style(for: effectiveAppearance).padding
        let row = Int(((CGFloat(y - height) - padding.height) / grid.cell.height).rounded())
        return (0..<grid.rows).contains(row) ? row : nil
    }

    /// `agent.read` `block: "last"`: the output of the last command the shell finished, found
    /// on the rows just above the prompt.
    func lastBlock() throws -> (command: TerminalCommand, output: String) {
        guard let last = lastCommand?.command else {
            throw ApiRouter.Failure("unavailable", "no command has finished in terminal \(objectID) since Canvas attached to it (its shell needs Ghostty's shell integration; read with lines instead)")
        }
        guard surface?.handle != nil, grid != nil else { throw ApiRouter.Failure("unavailable", "terminal \(objectID) isn't shown in a window") }
        guard surface?.readSelection()?.isEmpty ?? true else {
            throw ApiRouter.Failure("unavailable", "the user has text selected in terminal \(objectID); read with lines instead")
        }
        guard let cursorRow else { throw ApiRouter.Failure("unavailable", "terminal \(objectID) is scrolled back; read with lines instead") }
        for row in stride(from: cursorRow - 1, through: max(0, cursorRow - TerminalBlocks.promptRows - 1), by: -1) {
            guard let block = commandBlock(row: row, column: 0) else { continue }
            guard let command = block.command, command.exit == last.exit, command.durationMs == last.durationMs else { break }
            return (command, block.output)
        }
        return (last, "")
    }

    /// The terminal's current screen (not where the user scrolled to), soft-wrapped rows joined,
    /// for a mention of the whole terminal.
    func screenText() -> String? {
        guard let handle = surface?.handle, let grid else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(grid.columns - 1), y: UInt32(grid.rows - 1)),
            rectangle: false)
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(handle, selection, &out) else { return nil }
        defer { ghostty_surface_free_text(handle, &out) }
        guard let text = out.text, out.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: text, count: Int(out.text_len)), as: UTF8.self)
    }

    /// The screen as VoiceOver's text area, read from Ghostty (`screenText`, as a mention of the
    /// whole terminal reads it) only when asked, without the blank rows below the last output.
    private(set) lazy var accessibleText: AccessibleTextElement? = AccessibleTextElement(view: self, label: { "screen" }, read: { [weak self] in
        self?.screenText().map { AccessibleText($0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)) }
    })

    /// The terminal's width in cells, once Ghostty laid it out.
    var columns: Int? { grid?.columns }

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
        guard let surface, let grid, let cell = cell(at: point) else { return nil }
        let cwd = board.objects[objectID]?.props["cwd"]?.string
        let directories = [reportedCwd, cwd, board.root.path].compactMap { $0 }
        let files = BoardFiles.of(board.root)
        let listed = (root: files.root.path, files: files.current())
        let near = reportedCwd ?? cwd ?? board.root.path
        return TerminalReferences.hit(row: cell.row, column: cell.column, columns: grid.columns,
                                      read: { $0 < grid.rows ? surface.viewportRow($0, columns: grid.columns) : nil },
                                      resolve: { TerminalReferences.resolve($0, directories: directories, home: NSHomeDirectory(), isFile: TerminalReferences.isFile, listed: listed, near: near) })
    }

    /// A ⌘-click that found no file on a reference: the file may be newer than the board root's
    /// file list (a test just wrote it, and the click that made the list stale started the
    /// re-listing). Look again once the list is fresh, and open it then.
    private func retryLink(at point: NSPoint, newTile: Bool) {
        guard let surface, let grid, let cell = cell(at: point),
              TerminalReferences.hit(row: cell.row, column: cell.column, columns: grid.columns,
                                     read: { $0 < grid.rows ? surface.viewportRow($0, columns: grid.columns) : nil }, resolve: { $0 }) != nil else { return }
        BoardFiles.of(board.root).refresh { [weak self] _ in
            guard let self, let hit = self.link(at: point) else { return }
            self.open(hit, newTile: newTile)
        }
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
        if let test = hit.test {
            // A pytest node id: its line is the test's `def`, read off the main thread.
            let file = hit.file
            Task { [weak self] in
                let line = await offPool { (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { PytestNode.line(of: test, in: $0) } } ?? 1
                var located = hit
                located.test = nil
                located.lines = LineRange(start: line, end: line)
                self?.open(located, newTile: newTile)
            }
            return
        }
        let opened = board.openCode(path: hit.file, lines: hit.lines, beside: objectID, newTile: newTile)
        NSLog("Canvas: terminal %@ opened %@:%d-%d as %@ (%@)", objectID, hit.file, hit.lines.start, hit.lines.end, opened.id,
              opened.created ? (newTile ? "new tile" : "new preview") : opened.existing ? "existing" : "re-aimed preview")
        let source = grid.map { rects(hit.runs, grid: $0).reduce(NSRect.null) { $0.union($1) } } ?? .null
        onOpenedCode?(opened, source.isNull ? .null : underline.convert(source, to: nil))
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
            let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
            windowObservers = names.map { (app, app.addObserver(forName: $0, object: window, queue: .main, using: changed)) }
                + [NSApplication.didHideNotification, NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
                    .map { (app, app.addObserver(forName: $0, object: NSApp, queue: .main, using: changed)) }
                + [(workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: changed))]
        }
        updateSurfaceVisibility()
    }

    /// AppKit posts these before `occlusionState` settles (`didMiniaturize` arrives with the
    /// window still occlusion-visible, `didDeminiaturize` with it still occluded), so look again
    /// on the next main-loop turn. Ghostty's focus follows key window, app activation and
    /// minimizing (`updateSurfaceFocus`), after libghostty-spm's own key-window handlers ran.
    private func windowVisibilityChanged() {
        updateSurfaceVisibility()
        updateSurfaceFocus()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.updateSurfaceVisibility()
                self?.updateSurfaceFocus()
            }
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

    /// The row the cursor is on (the line being typed), across the terminal's width, in the
    /// terminal view's coordinates: what attention pills keep off while the terminal has the
    /// keyboard. Nil until the surface attaches and lays out.
    var caretRow: NSRect? {
        guard let handle = surface?.handle, let grid else { return nil }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        // Top-left origin; `y` is the bottom of the cursor's cell.
        ghostty_surface_ime_point(handle, &x, &y, &width, &height)
        let rowHeight = max(CGFloat(height), grid.cell.height)
        return NSRect(x: 0, y: terminal.bounds.height - CGFloat(y), width: terminal.bounds.width, height: rowHeight)
    }

    /// The terminal's theme background (a light Ghostty theme draws the default ink dark).
    var surfaceLuminance: Double? {
        DrawingStyle.luminance(TerminalConfig.shared.style(for: effectiveAppearance).background, in: effectiveAppearance)
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
    TerminalSurfaceScrollbarDelegate, TerminalSurfaceCommandFinishedDelegate {
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
        tile?.bell()
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        tile?.notice(Board.noticeMessage(title: title, body: body), bell: false)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        tile?.reportedCwd = path.isEmpty ? nil : path
        // The shell reports its directory at each prompt: whatever ran has finished.
        tile?.refreshProgram()
        tile?.commands.prompt(at: Date())
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        tile?.commandFinished(exit: exitCode, durationNanos: durationNanos)
    }

    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        tile?.scrollbar = scrollbar
    }

    func terminalDidClose(processAlive: Bool) {
        tile?.surfaceClosed(processAlive: processAlive)
    }
}
