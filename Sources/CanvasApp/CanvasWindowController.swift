import AppKit
import CanvasCore

/// One window per board: the canvas scene plus the selection tray.
@MainActor
final class CanvasWindowController: NSWindowController, NSWindowDelegate {
    let board: Board
    let canvas: CanvasView
    private let tray = TrayBar(frame: .zero)
    private let navigator = NavigatorPanel()
    private let nothingHere = NothingHerePill(frame: .zero)
    private let emptyHint = EmptyBoardHint()
    private let registry: BoardRegistry
    private var responderObservation: NSKeyValueObservation?
    private var drawing: ShapeLayer?

    init(board: Board, registry: BoardRegistry) {
        self.board = board
        self.registry = registry
        canvas = CanvasView(board: board)
        let window = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = board.root.lastPathComponent
        window.subtitle = board.root.path
        window.acceptsMouseMovedEvents = true
        window.setFrameAutosaveName("Canvas-\(board.id)")
        // Boards open as tabs of one window (AppDelegate.open adds them to the frontmost group).
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "net.waldin.canvas.board"
        super.init(window: window)
        window.delegate = self
        // Terminal references by file name (`core.py:10`) resolve through the listing.
        BoardFiles.of(board.root).refresh()

        let container = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        tray.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvas)
        container.addSubview(tray)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tray.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            tray.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            tray.heightAnchor.constraint(equalToConstant: 34),
            tray.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
            tray.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        window.contentView = container
        emptyHint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyHint)
        NSLayoutConstraint.activate([
            emptyHint.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyHint.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyHint.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        drawing = ShapeLayer.install(on: canvas, toolbarIn: container)
        canvas.chromeInsets = { [weak container, weak tray, weak drawing] in
            guard let container else { return NSEdgeInsets() }
            // The toolbar and tray sit at fixed offsets, so only a window never laid out needs a
            // pass here; attention pills ask on every pan step, sometimes from inside layout.
            if tray?.frame.isEmpty ?? false { container.layoutSubtreeIfNeeded() }
            let top = drawing?.toolbar.map { $0.isHidden ? 0 : container.bounds.maxY - $0.frame.minY } ?? 0
            let bottom = tray.map { $0.isHidden ? 0 : $0.frame.maxY } ?? 0
            return NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        }
        // Above the toolbar and tray, so the navigator is never covered.
        for view in [nothingHere, navigator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        let navigatorWidth = navigator.widthAnchor.constraint(equalToConstant: 560)
        navigatorWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            nothingHere.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            nothingHere.bottomAnchor.constraint(equalTo: tray.topAnchor, constant: -10),
            navigator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            navigator.topAnchor.constraint(equalTo: container.topAnchor, constant: 60),
            navigatorWidth,
            navigator.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        navigator.onGo = { [weak self] target in
            switch target {
            case .allContent: self?.canvas.zoomToFit()
            case .object(let id): self?.canvas.go(to: id)
            case .file(let path, let lines):
                self?.open(path: path, lines: lines)
            case .status: break
            }
        }
        navigator.searchSymbols = { [weak self] name in await self?.workspaceSymbols(named: name) ?? [] }
        nothingHere.onBack = { [weak self] in self?.canvas.zoomToFit() }
        canvas.onContentInViewChange = { [weak self] inView in self?.nothingHere.isHidden = inView }

        tray.onUnstage = { [weak self] id in try? self?.board.unstage(id) }
        canvas.onPromptTargetChange = { [weak self] in self?.refreshTray() }
        canvas.onPromptTargetTitle = { [weak self] in self?.scheduleTrayTitle() }
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged(window.firstResponder) }
        }
        settlePromptTarget()
        refreshTray()
        refreshTab()
        emptyHint.isHidden = !board.objects.isEmpty
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ event: BoardEvent) {
        canvas.apply(event)
        drawing?.apply(event)
        switch event {
        case .trayChanged: refreshTray()
        case .objectCreated, .objectDeleted:
            settlePromptTarget()
            refreshTray()
            refreshTab()
            emptyHint.isHidden = !board.objects.isEmpty
        case .objectUpdated(let object) where object.type == .terminal:
            // An agent starting or exiting in a terminal can move the target.
            settlePromptTarget()
            if object.id == canvas.promptTarget { refreshTray() }
            refreshTab()
        default: break
        }
    }

    private func refreshTray() {
        trayTitleWork?.cancel()
        trayTitleWork = nil
        let target = canvas.promptTarget.flatMap { board.objects[$0] }
        let title = target.map { PromptTarget.label($0, shownTitle: canvas.tiles[$0.id]?.title) }
        tray.show(board.tray, targetTitle: title, targetDrains: target.map(PromptTarget.runsAgent) ?? false,
                  hasTerminal: board.objects.values.contains { $0.type == .terminal })
    }

    /// What the tab last showed (`NeedsYou`), so a terminal's frequent updates redraw nothing.
    private var tabState: NeedsYou?

    /// The board's tab says when an agent on it needs the user, so one waiting on a background
    /// tab is seen: an orange dot for a blocked agent, a quieter green one for an agent that
    /// finished unseen (`NeedsYou`); nothing for working or idle agents. The tooltip says who
    /// and what.
    private func refreshTab() {
        guard let window else { return }
        let state = NeedsYou.of(board.objects.values)
        guard state != tabState else { return }
        tabState = state
        guard let state else {
            window.tab.accessoryView = nil
            window.tab.toolTip = nil
            return
        }
        // An accessory view, not a colored title: the tab bar draws titles in its own color.
        let blocked = state.level == .blocked
        window.tab.accessoryView = TabDot(color: blocked ? .systemOrange : .systemGreen.withAlphaComponent(0.75), diameter: blocked ? 9 : 7)
        let label = state.terminals.count == 1 ? board.objects[state.terminals[0]].map { PromptTarget.label($0, shownTitle: canvas.tiles[$0.id]?.title) } ?? "An agent" : "\(state.terminals.count) agents"
        window.tab.toolTip = blocked ? "\(label) needs you\(state.message.map { ": \($0)" } ?? "")" : "\(label) finished (not seen yet)"
    }

    private var trayTitleWork: DispatchWorkItem?

    /// The target's shown title changed. An agent retitles its terminal many times a second (a
    /// spinner), so the tray catches up at most once a second.
    private func scheduleTrayTitle() {
        guard trayTitleWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.refreshTray() }
        trayTitleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Terminals in the order they last had keyboard focus, most recent last.
    private var focusOrder: [ObjectID] = []

    /// `PromptTarget`: the last focused terminal running an agent, else the last focused
    /// terminal, else the board's only one, so a lone agent never needs a click and an editor
    /// or shell opened beside an agent doesn't take its mentions.
    private func settlePromptTarget() {
        focusOrder.removeAll { board.objects[$0] == nil }
        let target = PromptTarget.choose(focusOrder: focusOrder, objects: board.objects)
        if canvas.promptTarget != target { canvas.promptTarget = target }
    }

    /// Keyboard focus inside a terminal tile counts for the prompt target and marks it seen.
    private func firstResponderChanged(_ responder: NSResponder?) {
        var view = responder as? NSView
        while let current = view {
            if let terminal = current as? TerminalTile {
                focusOrder.removeAll { $0 == terminal.objectID }
                focusOrder.append(terminal.objectID)
                settlePromptTarget()
                board.markSeen(terminal.objectID)
                canvas.terminalFocused(terminal.objectID)
                return
            }
            view = current.superview
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        registry.frontmost = board.id
    }

    /// The board's tab or window closed (not app quit, which closes nothing).
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    /// The window content as the user sees it, with the viewport it shows. Content drawn outside
    /// AppKit (Ghostty's Metal, WebKit) is missing from `cacheDisplay`, so visible tiles swap in
    /// images of it while rendering.
    func snapshot(format: ImageFormat) -> (output: RenderOutput, viewport: Viewport)? {
        guard let window, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        let visible = canvas.documentVisibleRect
        let live = canvas.tiles.values.filter { $0.isLive && $0.frame.intersects(visible) }.map(\.content)
        canvas.tiles.values.forEach { $0.syncTitle() }
        live.forEach { $0.showSnapshot(true) }
        view.cacheDisplay(in: view.bounds, to: rep)
        live.forEach { $0.showSnapshot(false) }
        let encoded = format == .png ? rep.representation(using: .png, properties: [:]) : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        guard let encoded else { return nil }
        let backing = Double(rep.pixelsWide) / max(view.bounds.width, 1)
        let viewport = canvas.viewport
        let output = RenderOutput(image: encoded, format: format, width: rep.pixelsWide, height: rep.pixelsHigh, canvasRect: viewport.rect,
                                  scale: backing * viewport.zoom, objects: canvas.visibleObjects(pixelsPerPoint: backing))
        return (output, viewport)
    }

    // MARK: Actions

    @objc func newTerminal(_ sender: Any?) {
        canvas.createTerminal()
    }

    /// A sheet, not `runModal`: a modal run loop would stall every socket request.
    @objc func openCodeTile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = board.root
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self, panel] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.canvas.openForUser(.code, props: .object(["path": .string(self.board.relativePath(url.path))]))
        }
    }

    @objc func zoomToActual(_ sender: Any?) {
        canvas.zoomToActualSize()
    }

    @objc func zoomOut(_ sender: Any?) {
        canvas.zoomStep(in: false)
    }

    @objc func zoomIn(_ sender: Any?) {
        canvas.zoomStep(in: true)
    }

    /// Go to… opens (or closes) the navigator over this board. The board root's files are
    /// re-listed on every open; the list shown meanwhile is the previous one.
    @objc func toggleNavigator(_ sender: Any?) {
        if navigator.isOpen {
            navigator.close()
        } else {
            let files = BoardFiles.of(board.root)
            navigator.open(rows: canvas.navigatorRows(), files: files.index)
            files.refresh { [weak self] index in self?.navigator.update(files: index) }
        }
    }

    /// Go to's file and symbol rows: the code tile already showing the file (follow tiles
    /// excluded: they're their agent's) re-aimed at the lines (`Board.showCode`) and gone to;
    /// else a new one placed in view like any object the user asks for.
    private func open(path: String, lines: LineRange?) {
        let existing = board.objects.values
            .filter { $0.type == .code && $0.props["path"]?.string == path && $0.props["followOf"] == nil }
            .max { $0.z < $1.z }
        if let existing {
            if let lines { _ = try? board.showCode(path: path, range: lines, beside: existing.id) }
            return canvas.go(to: existing.id)
        }
        var props: [String: JSONValue] = ["path": .string(path)]
        if let lines { props["range"] = .object(["start": .number(Double(lines.start)), "end": .number(Double(lines.end))]) }
        canvas.openForUser(.code, props: .object(props))
    }

    /// When the language servers last answered a Go to symbol search with symbols (they are warm).
    private var symbolsAnswered: Date?

    /// Go to's symbol rows for `name`: the workspace symbols of the projects this board's code
    /// tiles show (else of the language most of the board root's files are in), from the app's
    /// language servers, started if needed. Files outside the board root are left out. When no
    /// server could answer (not installed, crashed), one status row says why, with its install
    /// hint, as Outline does, rather than claiming there are no such symbols.
    private func workspaceSymbols(named name: String) async -> [NavigatorRow] {
        let root = board.root
        var files = board.objects.values.filter { $0.type == .code }.compactMap { $0.props["path"]?.string }.map(board.absoluteURL)
        if files.isEmpty {
            let configs = LanguageServerConfig.defaults
            var counts: [String: Int] = [:]
            var first: [String: String] = [:]
            for path in BoardFiles.of(root).index.paths.prefix(20_000) {
                let url = URL(fileURLWithPath: path)
                guard let language = configs.first(where: { $0.languageID(for: url) != nil })?.language else { continue }
                counts[language, default: 0] += 1
                if first[language] == nil { first[language] = path }
            }
            if let most = counts.max(by: { $0.value < $1.value })?.key, let path = first[most] { files = [root.appendingPathComponent(path)] }
        }
        guard !files.isEmpty else { return [] }
        func ask() async -> Result<[LSPWorkspaceSymbol], Error> {
            do { return .success(try await CodeNavigation.languages.workspaceSymbols(name, files: files, boardRoot: root)) } catch { return .failure(error) }
        }
        var answer = await ask()
        // A server that just started answers before it has read the project (pyright: nothing at
        // all), so until one has answered with symbols lately, an empty answer is asked again
        // for a while; the panel says "Searching symbols…" meanwhile.
        let warm = symbolsAnswered.map { Date().timeIntervalSince($0) < 240 } ?? false
        var retries = warm ? 0 : 10
        while case .success(let found) = answer, found.isEmpty, retries > 0, !Task.isCancelled {
            retries -= 1
            try? await Task.sleep(for: .seconds(1))
            answer = await ask()
        }
        let symbolsFound: [LSPWorkspaceSymbol]
        switch answer {
        case .success(let found): symbolsFound = found
        case .failure(let error):
            if error is CancellationError { return [] }
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return [NavigatorRow(target: .status, title: reason, kind: "", dot: nil, toolTip: reason)]
        }
        var symbols = symbolsFound
        if !symbols.isEmpty { symbolsAnswered = Date() }
        // Servers match fuzzily (`_resolve_pager_command` for `resolve_command`): the name itself
        // first, then names starting with it, each in the server's order.
        let lowered = name.lowercased()
        func rank(_ symbol: LSPWorkspaceSymbol) -> Int { symbol.name == name ? 0 : symbol.name.lowercased() == lowered ? 1 : symbol.name.lowercased().hasPrefix(lowered) ? 2 : 3 }
        symbols = symbols.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        let rootPath = root.resolvingSymlinksInPath().path + "/"
        var rows: [NavigatorRow] = []
        for symbol in symbols {
            let file = symbol.location.url.resolvingSymlinksInPath().path
            guard file.hasPrefix(rootPath) else { continue }
            let path = String(file.dropFirst(rootPath.count))
            let line = symbol.location.range.start.line + 1
            rows.append(NavigatorRow(target: .file(path, lines: LineRange(start: line, end: line)), title: symbol.name, kind: symbol.kindName.capitalized, dot: nil,
                                     subtitle: [symbol.container, "\(path):\(line)"].compactMap { $0 }.joined(separator: " · "), toolTip: "\(path):\(line)"))
            if rows.count == NavigatorPanel.maxFileRows { break }
        }
        return rows
    }

    @objc func zoomToFit(_ sender: Any?) {
        canvas.zoomToFit()
    }

    @objc func toggleLassoSelection(_ sender: Any?) {
        CanvasView.lassoSelection.toggle()
        (sender as? NSMenuItem)?.state = CanvasView.lassoSelection ? .on : .off
    }

    @objc func exitGroup(_ sender: Any?) {
        canvas.exitGroup()
    }

    /// ⌘Z undoes the latest board change (the user's or an agent's). A text field or editor with
    /// its own pending edits undoes those first.
    @objc func undoCanvas(_ sender: Any?) {
        if let text = window?.firstResponder as? NSTextView, text.isEditable, let manager = text.undoManager, manager.canUndo {
            return manager.undo()
        }
        board.undo()
    }

    @objc func redoCanvas(_ sender: Any?) {
        if let text = window?.firstResponder as? NSTextView, text.isEditable, let manager = text.undoManager, manager.canRedo {
            return manager.redo()
        }
        board.redo()
    }

    @objc func deleteSelection(_ sender: Any?) {
        canvas.deleteSelection()
    }

    @objc func selectAllObjects(_ sender: Any?) {
        canvas.selectAll()
    }

    @objc func groupSelection(_ sender: Any?) {
        canvas.groupSelection()
    }

    @objc func ungroupSelection(_ sender: Any?) {
        canvas.ungroupSelection()
    }

    @objc func bringToFront(_ sender: Any?) {
        canvas.bringToFront()
    }

    @objc func sendToBack(_ sender: Any?) {
        canvas.sendToBack()
    }

    /// Hyper-V (Edit ▸ Paste Mentions into Terminal): the tray's context block pasted into the
    /// prompt-target terminal as one bracketed paste without Enter, for agents with no prompt hook
    /// to drain it (aider, a bare shell); the pasted mentions leave the tray.
    @objc func pasteMentions(_ sender: Any?) {
        guard !board.tray.isEmpty, let target = canvas.promptTarget, let terminal = canvas.tiles[target]?.content as? TerminalTile else { return }
        let board = board
        Task { @MainActor [weak terminal] in
            let drained = await board.drain(peek: true, caller: target)
            // Ends on its own line, so what the user types next starts below the block.
            guard !drained.context.isEmpty, let terminal, terminal.paste(drained.context + "\n", submit: false) else { return }
            board.commit(drained.mentions.map(\.id))
        }
    }

    // MARK: The context menus' actions in the menu bar

    @objc func goToNextNeedsYou(_ sender: Any?) {
        canvas.goToNextNeedsYou()
    }

    @objc func reviewChanges(_ sender: Any?) {
        canvas.reviewChanges()
    }

    @objc func clearAttentionMarkers(_ sender: Any?) {
        board.clearAllAttention()
    }

    @objc func toggleFollowFiles(_ sender: Any?) {
        canvas.toggleFollow()
    }

    /// Object ▸ Scale ▸ a preset (the item's `tag` in percent).
    @objc func scaleSelection(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        canvas.scaleSelection(to: Double(item.tag) / 100)
    }

    @objc func copyObjectIDs(_ sender: Any?) {
        canvas.copyIDs()
    }

    @objc func enterGroup(_ sender: Any?) {
        guard let group = canvas.selectedGroup else { return }
        canvas.enter(group: group)
    }

    @objc func goToDefinition(_ sender: Any?) { canvas.keyboardCodeTile?.navigate(.definition) }
    @objc func openDefinitionInNewTile(_ sender: Any?) { canvas.keyboardCodeTile?.navigate(.definitionInNewTile) }
    @objc func findReferences(_ sender: Any?) { canvas.keyboardCodeTile?.navigate(.references) }
    @objc func showOutline(_ sender: Any?) { canvas.keyboardCodeTile?.navigate(.outline) }

    /// Whether a menu item applies now (AppDelegate forwards the menu bar's validation here).
    func validate(_ item: NSMenuItem) -> Bool {
        let selection = canvas.selection
        switch item.action {
        case #selector(undoCanvas(_:)): return textUndoManager?.canUndo == true || board.history.canUndo
        case #selector(redoCanvas(_:)): return textUndoManager?.canRedo == true || board.history.canRedo
        case #selector(deleteSelection(_:)), #selector(bringToFront(_:)), #selector(sendToBack(_:)): return !selection.isEmpty
        case #selector(groupSelection(_:)): return selection.count >= 2
        case #selector(ungroupSelection(_:)):
            return board.objects.values.contains { $0.type == .group && (selection.contains($0.id) || GroupSpec($0.props)?.members.contains(where: selection.contains) == true) }
        case #selector(pasteMentions(_:)): return !board.tray.isEmpty && canvas.promptTarget != nil
        case #selector(exitGroup(_:)): return canvas.enteredGroup != nil
        case #selector(enterGroup(_:)): return canvas.selectedGroup != nil
        case #selector(copyObjectIDs(_:)):
            item.title = selection.count > 1 ? "Copy Object IDs" : "Copy Object ID"
            return !selection.isEmpty
        case #selector(goToNextNeedsYou(_:)): return canvas.somethingNeedsYou
        case #selector(clearAttentionMarkers(_:)): return !board.attention.isEmpty
        case #selector(toggleFollowFiles(_:)):
            guard let terminal = canvas.followTerminal else {
                item.state = .off
                return false
            }
            item.state = canvas.follows(terminal) ? .on : .off
            return true
        case #selector(scaleSelection(_:)):
            guard let scales = canvas.selectionScales else {
                item.state = .off
                return false
            }
            let scale = Double(item.tag) / 100
            item.state = scales == [scale] && item.tag != 100 ? .on : .off
            return item.tag != 100 || scales != [1]
        case #selector(goToDefinition(_:)), #selector(openDefinitionInNewTile(_:)), #selector(findReferences(_:)), #selector(showOutline(_:)):
            return canvas.keyboardCodeTile?.canNavigate == true
        default: return true
        }
    }

    /// A text view with its own undo history holding the keyboard (a note being edited).
    private var textUndoManager: UndoManager? {
        guard let text = window?.firstResponder as? NSTextView, text.isEditable else { return nil }
        return text.undoManager
    }

    /// The View menu's navigation shortcuts, matched on the key's characters: ⌘P, ⌘9, ⌘0, ⌘= (and
    /// ⌘+), ⌘-. Nil for anything else, which stays with the focused view.
    static func navigationAction(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.charactersIgnoringModifiers, modifiers) {
        case ("p", .command): return #selector(toggleNavigator(_:))
        case ("9", .command): return #selector(zoomToFit(_:))
        case ("0", .command): return #selector(zoomToActual(_:))
        case ("=", .command), ("+", .command), ("+", [.command, .shift]): return #selector(zoomIn(_:))
        case ("-", .command): return #selector(zoomOut(_:))
        default: return nil
        }
    }

    /// ⌥⌘-arrow, by key code (the characters an arrow reports vary with modifiers). Ghostty's
    /// ⌥⌘-arrow (go to split) has no splits to go to here, and shells never see ⌘.
    static func tileHeading(for event: NSEvent) -> Layout.Heading? {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .option] else { return nil }
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    /// The chord a key press is, as Ghostty keybinds name it: its modifiers and unshifted
    /// character, or the key's name for keys without one.
    static func keyChord(for event: NSEvent) -> GhosttyConfig.KeyChord? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags
        var modifiers: GhosttyConfig.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if let name = namedKeys[event.keyCode] { return .init(modifiers, name) }
        guard let character = event.characters(byApplyingModifiers: [])?.lowercased(), character.count == 1 else { return nil }
        return .init(modifiers, character)
    }

    private static let namedKeys: [UInt16: String] = [
        36: "enter", 48: "tab", 49: "space", 51: "backspace", 53: "escape", 117: "delete", 115: "home", 119: "end",
        116: "page_up", 121: "page_down", 123: "arrow_left", 124: "arrow_right", 125: "arrow_down", 126: "arrow_up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    /// Menu items a focused terminal keeps: editing (Copy, Paste, Select All) and ⌘⌫, which
    /// Ghostty sends as "delete line" and which must never delete the canvas selection.
    private static let terminalMenuActions: Set<Selector> = [#selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)), #selector(AppDelegate.deleteSelection(_:))]

    /// The main-menu item `event` is the key equivalent of.
    static func menuItem(for event: NSEvent, in menu: NSMenu?) -> NSMenuItem? {
        guard event.type == .keyDown, let menu, let chord = keyChord(for: event) else { return nil }
        for item in menu.items {
            if let found = menuItem(for: event, in: item.submenu) { return found }
            guard !item.keyEquivalent.isEmpty else { continue }
            var modifiers: GhosttyConfig.Modifiers = []
            let mask = item.keyEquivalentModifierMask
            if mask.contains(.command) { modifiers.insert(.command) }
            if mask.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
            if mask.contains(.option) { modifiers.insert(.option) }
            if mask.contains(.control) { modifiers.insert(.control) }
            if chord == .init(modifiers, item.keyEquivalent.lowercased()) { return item }
        }
        return nil
    }

    /// Board shortcuts taken ahead of the focused view (see `CanvasWindow`). ⌘W closes the
    /// selection or the focused terminal and, with neither, goes on to the window's own close;
    /// ⌘F finds in a code tile and otherwise stays with the terminal or page. Hyper-V pastes the
    /// tray's mentions; a focused terminal would otherwise send the chord to its program as an
    /// encoded key (zsh prints it at the prompt). In a focused terminal, the user's Ghostty
    /// bindings of new window, tab or split open a terminal beside it and close surface closes it
    /// (`TerminalConfig.remaps`), and Canvas's menu shortcuts beat Ghostty's own bindings (its
    /// defaults bind ⌘T, ⌘N, ⌘Z, ⌘Q, ⌘⇧[ and ⌘⇧] to tab, window and app actions the embedded
    /// library can't perform, so the key would do nothing).
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        if let action = Self.navigationAction(for: event) {
            perform(action, with: self)
            return true
        }
        if let heading = Self.tileHeading(for: event) {
            canvas.moveToNeighbor(heading)
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .keyDown, modifiers == [.command, .shift, .option, .control], event.charactersIgnoringModifiers?.lowercased() == "v", window?.attachedSheet == nil {
            pasteMentions(nil)
            return true
        }
        guard event.type == .keyDown, window?.attachedSheet == nil else { return false }
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "w": if canvas.closeSelectionOrFocused() { return true }
            case "f": if canvas.findInCodeTile() { return true }
            case "l": if canvas.focusBrowserAddress() { return true }
            default: break
            }
        }
        guard let terminal = canvas.focusedTerminal else { return false }
        if let chord = Self.keyChord(for: event), let action = TerminalConfig.shared.remaps[chord] {
            switch action {
            case .newTerminal: canvas.createTerminal(beside: terminal)
            case .closeTerminal: canvas.delete([terminal])
            }
            return true
        }
        if let item = Self.menuItem(for: event, in: NSApp.mainMenu), let action = item.action, !Self.terminalMenuActions.contains(action) {
            return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        }
        return false
    }
}

/// A board window. Canvas shortcuts reach the canvas before the focused view: the window gets
/// key equivalents ahead of its views and the main menu (AppKit's order for a real key press),
/// and a focused terminal would otherwise claim ⌘0/⌘=/⌘-/⌘9 as Ghostty bindings (font size,
/// tabs), ⌘W as close surface, and a web view ⌘=/⌘- as page zoom. Everything else (⌘C, ⌘V, ⌘A,
/// typing) stays with the focused view.
final class CanvasWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let controller = windowController as? CanvasWindowController, controller.handleKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The dot at the trailing edge of a board's tab while an agent on it needs the user.
private final class TabDot: NSView {
    private let color: NSColor
    private let diameter: CGFloat

    init(color: NSColor, diameter: CGFloat) {
        self.color = color
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter + 6, height: diameter + 6))
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter + 6, height: diameter + 6) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)).fill()
    }
}
