import AppKit
import CanvasCore

/// One window per board: the canvas scene plus the selection tray.
@MainActor
final class CanvasWindowController: NSWindowController, NSWindowDelegate {
    let board: Board
    let canvas: CanvasView
    private let tray = TrayBar(frame: .zero)
    private let registry: BoardRegistry
    private var responderObservation: NSKeyValueObservation?
    private var drawing: ShapeLayer?

    init(board: Board, registry: BoardRegistry) {
        self.board = board
        self.registry = registry
        canvas = CanvasView(board: board)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = board.root.lastPathComponent
        window.subtitle = board.root.path
        window.acceptsMouseMovedEvents = true
        window.setFrameAutosaveName("Canvas-\(board.id)")
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
        drawing = ShapeLayer.install(on: canvas, toolbarIn: container)

        tray.onUnstage = { [weak self] id in try? self?.board.unstage(id) }
        canvas.onPromptTargetChange = { [weak self] in self?.refreshTray() }
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged(window.firstResponder) }
        }
        refreshTray()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ event: BoardEvent) {
        canvas.apply(event)
        drawing?.apply(event)
        switch event {
        case .trayChanged, .objectDeleted: refreshTray()
        case .objectUpdated(let object) where object.id == canvas.promptTarget: refreshTray()
        default: break
        }
    }

    private func refreshTray() {
        let title = canvas.promptTarget.flatMap { board.objects[$0] }.map(TileFrameView.title(for:))
        tray.show(board.tray, targetTitle: title)
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

    /// The window content as the user sees it, with the viewport it shows. Content drawn outside
    /// AppKit (Ghostty's Metal, WebKit) is missing from `cacheDisplay`, so visible tiles swap in
    /// images of it while rendering.
    func snapshot(format: ImageFormat) -> (output: RenderOutput, viewport: Viewport)? {
        guard let window, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        let visible = canvas.documentVisibleRect
        let live = canvas.tiles.values.filter { $0.isLive && $0.frame.intersects(visible) }.map(\.content)
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
        canvas.zoom(to: 1)
    }

    @objc func zoomOut(_ sender: Any?) {
        canvas.zoom(to: canvas.magnification / 2)
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
}
