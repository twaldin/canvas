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
            }
        }
        nothingHere.onBack = { [weak self] in self?.canvas.zoomToFit() }
        canvas.onContentInViewChange = { [weak self] inView in self?.nothingHere.isHidden = inView }

        tray.onUnstage = { [weak self] id in try? self?.board.unstage(id) }
        canvas.onPromptTargetChange = { [weak self] in self?.refreshTray() }
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged(window.firstResponder) }
        }
        settlePromptTarget()
        refreshTray()
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
            emptyHint.isHidden = !board.objects.isEmpty
        case .objectUpdated(let object) where object.id == canvas.promptTarget: refreshTray()
        default: break
        }
    }

    private func refreshTray() {
        let title = canvas.promptTarget.flatMap { board.objects[$0] }.map(TileFrameView.title(for:))
        tray.show(board.tray, targetTitle: title, hasTerminal: board.objects.values.contains { $0.type == .terminal })
    }

    /// The terminal that last had keyboard focus; while none has (or it was closed), the board's
    /// only terminal, so a lone agent never needs a click before mentions go to it.
    private func settlePromptTarget() {
        if let target = canvas.promptTarget, board.objects[target] != nil { return }
        let terminals = board.objects.values.filter { $0.type == .terminal }
        let sole = terminals.count == 1 ? terminals.first?.id : nil
        if canvas.promptTarget != sole { canvas.promptTarget = sole }
    }

    /// Keyboard focus inside a terminal tile makes it the prompt target and marks it seen.
    private func firstResponderChanged(_ responder: NSResponder?) {
        var view = responder as? NSView
        while let current = view {
            if let terminal = current as? TerminalTile {
                if canvas.promptTarget != terminal.objectID { canvas.promptTarget = terminal.objectID }
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
            self.board.create(type: .code, props: .object(["path": .string(self.board.relativePath(url.path))]))
        }
    }

    @objc func zoomToActual(_ sender: Any?) {
        canvas.zoomToActualSize()
    }

    @objc func zoomOut(_ sender: Any?) {
        canvas.zoom(to: canvas.magnification / 2)
    }

    @objc func zoomIn(_ sender: Any?) {
        canvas.zoom(to: canvas.magnification * 2)
    }

    /// Go to… opens (or closes) the navigator over this board.
    @objc func toggleNavigator(_ sender: Any?) {
        if navigator.isOpen {
            navigator.close()
        } else {
            navigator.open(rows: canvas.navigatorRows())
        }
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
}

/// A board window. Canvas navigation shortcuts reach the canvas before the focused view: the
/// window gets key equivalents ahead of its views and the main menu (AppKit's order for a real
/// key press), and a focused terminal would otherwise claim ⌘0/⌘=/⌘-/⌘9 as Ghostty bindings
/// (font size, tabs) and a web view ⌘=/⌘- as page zoom. Everything else (⌘C, ⌘V, ⌘A, typing)
/// stays with the focused view.
final class CanvasWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let controller = windowController as? CanvasWindowController, let action = CanvasWindowController.navigationAction(for: event) {
            controller.perform(action, with: self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
