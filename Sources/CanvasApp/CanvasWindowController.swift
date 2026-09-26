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
                return
            }
            view = current.superview
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        registry.frontmost = board.id
    }

    /// The window content as the user sees it. Content drawn outside AppKit (Ghostty's Metal,
    /// WebKit) is missing from `cacheDisplay`, so visible tiles swap in images of it while rendering.
    func snapshotPNG() -> (png: Data, width: Int, height: Int)? {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        let visible = canvas.documentVisibleRect
        let live = canvas.tiles.values.filter { $0.isLive && $0.frame.intersects(visible) }.map(\.content)
        live.forEach { $0.showSnapshot(true) }
        view.cacheDisplay(in: view.bounds, to: rep)
        live.forEach { $0.showSnapshot(false) }
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, rep.pixelsWide, rep.pixelsHigh)
    }

    // MARK: Actions

    @objc func newTerminal(_ sender: Any?) {
        let object = board.create(type: .terminal, props: .object(["cwd": .string(board.root.path), "command": .array([])]))
        DispatchQueue.main.async { [weak self] in
            (self?.canvas.tiles[object.id]?.content as? TerminalTile)?.focus()
        }
    }

    @objc func openCodeTile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.directoryURL = board.root
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        board.create(type: .code, props: .object(["path": .string(board.relativePath(url.path)), "mode": .string("source")]))
    }

    @objc func zoomToActual(_ sender: Any?) {
        canvas.animator().magnification = 1.0
    }

    @objc func zoomOut(_ sender: Any?) {
        canvas.animator().magnification = max(canvas.minMagnification, canvas.magnification / 2)
    }

    @objc func closeSelected(_ sender: Any?) {
        for id in canvas.selection { canvas.close(id) }
    }
}
