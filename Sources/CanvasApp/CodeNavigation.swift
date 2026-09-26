import AppKit
import CanvasCore

/// What a code view offers the language features. Implemented by code tiles.
@MainActor
protocol CodeNavigationHost: AnyObject {
    /// Board-relative path of the file shown.
    var navigationPath: String { get }
    /// The view showing the code; hover, ⌘-click, and right-click are handled over it.
    var navigationView: NSView { get }
    /// Height of one row, so panels open just below the hovered line.
    var navigationLineHeight: CGFloat { get }
    /// Source position under `point` (in `navigationView`'s coordinates): 1-based line,
    /// 0-based UTF-16 column on the current side; nil over peeked base rows and gutters.
    func sourcePosition(atViewPoint point: NSPoint) -> (line: Int, character: Int)?
    /// Scrolls a 1-based source line into view.
    func reveal(line: Int)
    /// Re-aims the view at lines of its own file (a same-file definition).
    func aim(at lines: LineRange)
}

/// Language features for one code view, answered by the app's shared language servers:
///  - hover (pointer still for ~500 ms) shows the server's hover docs; moving cancels the request
///  - ⌘-click goes to the definition: same file re-aims the tile, another file opens a code tile
///    beside it; ⌥⌘-click always opens a new tile
///  - the context menu adds Go to Definition, Find References, and Outline
///  - the Outline button lists the file's symbols; choosing one reveals it
/// Code tiles never take keyboard focus, so nothing here does either.
@MainActor
final class CodeNavigation: NSObject {
    /// Shared by every code view in the app (one server per language and project root).
    nonisolated static let languages = LanguageService()

    /// App quit waits for the language servers to be gone (SIGKILL after 2 s), so none outlives
    /// the app. Returns `.terminateLater` while they're ending and replies when they have.
    static func terminateServers() -> NSApplication.TerminateReply {
        guard languages.liveProcessCount > 0 else { return .terminateNow }
        Task.detached {
            await languages.terminateAll(grace: .seconds(2))
            // While termination is deferred the main run loop runs only in the modal-panel mode,
            // which doesn't service the main queue (so not MainActor jobs either).
            RunLoop.main.perform(inModes: [.modalPanel, .default]) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }

    private static let hoverDelay: TimeInterval = 0.5
    private static let controllers = NSHashTable<CodeNavigation>.weakObjects()
    private static var monitor: Any?

    private weak var host: CodeNavigationHost?
    private weak var codeView: NSView?
    private let board: Board
    private let tile: ObjectID

    /// Hover timing without a timer per mouse move: moves only stamp `lastMove`; one pending
    /// perform re-arms itself until the pointer has been still for `hoverDelay`.
    private var lastMove: TimeInterval = 0
    private var hoverScheduled = false
    private var pointer: NSPoint?
    private var hoverTask: Task<Void, Never>?
    /// What the visible hover describes, so moving within it keeps it open.
    private var hoverShown: (position: LSPPosition, range: LSPRange?)?
    private var hoverPanel: NavigationPanel?
    /// Bumped whenever hover work is cancelled, so a late answer can't show a stale hover.
    private var hoverGeneration = 0
    /// The list or message panel this view opened.
    private weak var panel: NavigationPanel?
    private var observingTileFrame = false
    private var lease: DocumentLease?
    /// Where a context menu was opened, for its actions.
    private var menuContext: (position: (line: Int, character: Int)?, anchor: NSPoint)?
    private var actionTask: Task<Void, Never>?

    /// `accessories` is the host's header: the Outline button goes at its top right, inside the
    /// trailing `reservedWidth` points the host keeps free.
    init(host: CodeNavigationHost, board: Board, tile: ObjectID, accessories: NSView, reservedWidth: CGFloat) {
        self.host = host
        self.board = board
        self.tile = tile
        let codeView = host.navigationView
        self.codeView = codeView
        super.init()
        codeView.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        // Scrolling or new content (a re-aim, a reload) moves what the panels point at.
        if let clip = codeView.enclosingScrollView?.contentView {
            NotificationCenter.default.addObserver(self, selector: #selector(contentMoved), name: NSView.boundsDidChangeNotification, object: clip)
        }
        installOutlineButton(in: accessories, reservedWidth: reservedWidth)
        Self.controllers.add(self)
        Self.installMonitor()
    }

    private var file: URL? {
        host.map { board.absoluteURL($0.navigationPath) }
    }

    // MARK: Hover

    @objc func mouseMoved(with event: NSEvent) {
        guard let codeView, event.window === codeView.window else { return }
        pointer = event.locationInWindow
        if let hoverPanel, hoverPanel.superview != nil {
            if hoverPanel.contains(windowPoint: event.locationInWindow, in: event.window) { return }
            if let shown = hoverShown, let position = position(atWindowPoint: event.locationInWindow), covers(shown, position) { return }
            dismissHover()
        }
        hoverTask?.cancel()
        hoverTask = nil
        lastMove = ProcessInfo.processInfo.systemUptime
        guard !hoverScheduled else { return }
        hoverScheduled = true
        perform(#selector(hoverDue), with: nil, afterDelay: Self.hoverDelay)
    }

    @objc func mouseExited(with event: NSEvent) {
        cancelPendingHover()
        if let hoverPanel, hoverPanel.contains(windowPoint: event.locationInWindow, in: event.window) { return }
        dismissHover()
    }

    @objc func mouseEntered(with event: NSEvent) {}

    @objc private func contentMoved() {
        dismissAll()
    }

    /// The host showed new content (a re-aim or a reload): panels describe what was there.
    func contentChanged() {
        dismissAll()
    }

    /// The tile moved, was resized, hidden, re-aimed, or removed: nothing shown or pending is
    /// about what's on screen anymore.
    @objc private func dismissAll() {
        cancelPendingHover()
        dismissHover()
        actionTask?.cancel()
        actionTask = nil
        panel?.dismiss()
    }

    private func cancelPendingHover() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hoverDue), object: nil)
        hoverScheduled = false
        hoverTask?.cancel()
        hoverTask = nil
        hoverGeneration += 1
    }

    @objc private func hoverDue() {
        let still = ProcessInfo.processInfo.systemUptime - lastMove
        guard still >= Self.hoverDelay else {
            perform(#selector(hoverDue), with: nil, afterDelay: Self.hoverDelay - still)
            return
        }
        hoverScheduled = false
        guard let pointer, let codeView, let file, let position = position(atWindowPoint: pointer) else { return }
        let anchor = codeView.convert(pointer, from: nil)
        let root = board.root
        lease(file)
        let generation = hoverGeneration
        hoverTask = Task { [weak self] in
            let hover = try? await Self.languages.hover(file: file, boardRoot: root, at: position)
            guard let self, let hover, !Task.isCancelled, self.hoverGeneration == generation else { return }
            self.showHover(hover, at: position, anchor: anchor)
        }
    }

    /// Shows hover docs for `position` below `anchor` (in the text view's coordinates).
    func showHover(_ hover: LSPHover, at position: LSPPosition, anchor: NSPoint) {
        guard let codeView else { return }
        let panel = NavigationPanel.hover(hover.markdown)
        panel.onPointerExit = { [weak self, weak panel] in
            guard let self, let panel, self.hoverPanel === panel else { return }
            self.dismissHover()
        }
        panel.show(below: anchor, lineHeight: lineHeight, in: codeView)
        observeTileFrame(codeView)
        hoverPanel = panel
        hoverShown = (position, hover.range)
    }

    private func dismissHover() {
        hoverPanel?.dismiss()
        hoverPanel = nil
        hoverShown = nil
    }

    private func covers(_ shown: (position: LSPPosition, range: LSPRange?), _ position: LSPPosition) -> Bool {
        shown.range?.contains(position) ?? (shown.position == position)
    }

    private func position(atWindowPoint point: NSPoint) -> LSPPosition? {
        guard let host, let codeView else { return nil }
        let local = codeView.convert(point, from: nil)
        guard codeView.visibleRect.contains(local), let position = host.sourcePosition(atViewPoint: local) else { return nil }
        return LSPPosition(line: position.line - 1, character: position.character)
    }

    private var lineHeight: CGFloat {
        host?.navigationLineHeight ?? 18
    }

    // MARK: Definition and references

    /// ⌘-click (⌥⌘-click with `newTile`) at a point in the text view.
    func goToDefinition(atViewPoint point: NSPoint, newTile: Bool) {
        guard let host, let position = host.sourcePosition(atViewPoint: point) else { return }
        goToDefinition(at: position, anchor: point, newTile: newTile)
    }

    private func goToDefinition(at position: (line: Int, character: Int), anchor: NSPoint, newTile: Bool) {
        run(anchor: anchor) { [weak self] file, root in
            let locations = try await Self.languages.definition(file: file, boardRoot: root, at: LSPPosition(line: position.line - 1, character: position.character))
            guard let self else { return }
            switch locations.count {
            case 0: await self.showEmpty("No definition found", file: file, root: root, anchor: anchor)
            case 1: self.open(locations[0], newTile: newTile)
            default:
                let lines = await Self.languages.lineTexts(locations)
                self.showLocations("\(locations.count) definitions", locations, lines: lines, anchor: anchor, newTile: newTile)
            }
        }
    }

    func findReferences(atViewPoint point: NSPoint) {
        guard let host, let position = host.sourcePosition(atViewPoint: point) else { return }
        findReferences(at: position, anchor: point)
    }

    private func findReferences(at position: (line: Int, character: Int), anchor: NSPoint) {
        showMessage("Finding references…", anchor: anchor)
        run(anchor: anchor) { [weak self] file, root in
            let locations = try await Self.languages.references(file: file, boardRoot: root, at: LSPPosition(line: position.line - 1, character: position.character))
            guard let self else { return }
            guard !locations.isEmpty else { return await self.showEmpty("No references found", file: file, root: root, anchor: anchor) }
            let lines = await Self.languages.lineTexts(locations)
            self.showLocations(locations.count == 1 ? "1 reference" : "\(locations.count) references", locations, lines: lines, anchor: anchor, newTile: false)
        }
    }

    private func showLocations(_ title: String, _ locations: [LSPLocation], lines: [String], anchor: NSPoint, newTile: Bool) {
        let rows = zip(locations, lines).map { location, line in
            NavigationPanel.Row(title: "\(boardPath(location.url)):\(location.range.start.line + 1)", detail: line) { [weak self] in
                NavigationPanel.current?.dismiss()
                self?.open(location, newTile: newTile)
            }
        }
        present(NavigationPanel.list(title: title, rows: rows), anchor: anchor)
    }

    /// An empty answer while the server is still loading or indexing the project (sourcekit-lsp
    /// answers from fallback settings and an empty index until then) says so, instead of
    /// claiming there is nothing.
    private func showEmpty(_ text: String, file: URL, root: URL, anchor: NSPoint) async {
        let server = await Self.languages.existingServer(for: file, boardRoot: root)
        let busy = await server?.activity ?? []
        if !busy.isEmpty { return showMessage("\(text) yet — \(busy.joined(separator: ", ")) in progress", anchor: anchor) }
        showMessage([text, server?.config.emptyResultHint].compactMap { $0 }.joined(separator: ". "), anchor: anchor)
    }

    /// Same file: re-aim this tile (the user's own jump, never held back like an agent's
    /// re-aim). Another file (or `newTile`): a code tile beside this one.
    private func open(_ location: LSPLocation, newTile: Bool) {
        guard let host else { return }
        let path = boardPath(location.url)
        let lines = location.range.lines
        if !newTile, path == boardPath(board.absoluteURL(host.navigationPath)) {
            host.aim(at: lines)
        } else {
            let range = JSONValue.object(["start": .number(Double(lines.start)), "end": .number(Double(lines.end))])
            let size = Board.defaultSize(.code)
            board.create(type: .code, props: .object(["path": .string(path), "range": range]), frame: board.place(width: size.w, height: size.h, near: tile))
        }
    }

    /// Board-relative when under the root. Servers report symlink-resolved paths (/private/tmp
    /// for /tmp), so both sides are resolved before comparing.
    private func boardPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        let root = board.root.resolvingSymlinksInPath().path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : board.relativePath(path)
    }

    // MARK: Outline

    private func installOutlineButton(in container: NSView, reservedWidth: CGFloat) {
        let button = OutlineButton(image: NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Outline") ?? NSImage(), target: self, action: #selector(outlineClicked(_:)))
        button.toolTip = "Outline"
        button.onDetach = { [weak self] in self?.dismissAll() }
        let size: CGFloat = 20
        let top = container.isFlipped ? 3 : container.bounds.height - size - 3
        let inset = min(8, max(0, (reservedWidth - size) / 2))
        button.frame = NSRect(x: container.bounds.width - size - inset, y: top, width: size, height: size)
        button.autoresizingMask = container.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        container.addSubview(button)
    }

    @objc private func outlineClicked(_ sender: NSButton) {
        guard let codeView else { return }
        let anchor = codeView.convert(NSPoint(x: sender.frame.maxX, y: sender.frame.midY), from: sender.superview)
        showOutline(anchor: NSPoint(x: max(0, anchor.x - 240), y: anchor.y))
    }

    func showOutline(anchor: NSPoint) {
        run(anchor: anchor) { [weak self] file, root in
            let symbols = LSPSymbol.flatten(try await Self.languages.documentSymbols(file: file, boardRoot: root))
            guard let self else { return }
            guard !symbols.isEmpty else { return self.showMessage("No symbols", anchor: anchor) }
            let rows = symbols.map { entry in
                NavigationPanel.Row(title: entry.symbol.name, detail: entry.symbol.kindName, indent: entry.depth) { [weak self] in
                    NavigationPanel.current?.dismiss()
                    self?.host?.reveal(line: entry.symbol.selectionRange.start.line + 1)
                }
            }
            self.present(NavigationPanel.list(title: "Outline", rows: rows), anchor: anchor)
        }
    }

    // MARK: Context menu

    func contextMenu(for event: NSEvent) {
        guard let host, let codeView else { return }
        let point = codeView.convert(event.locationInWindow, from: nil)
        let position = host.sourcePosition(atViewPoint: point)
        menuContext = (position, point)
        // Build on the view's own menu (copied: AppKit shares it) so its items stay available.
        let menu = (codeView.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        var items: [NSMenuItem] = []
        if position != nil {
            items.append(NSMenuItem(title: "Go to Definition", action: #selector(menuDefinition), keyEquivalent: ""))
            items.append(NSMenuItem(title: "Open Definition in New Tile", action: #selector(menuDefinitionNewTile), keyEquivalent: ""))
            items.append(NSMenuItem(title: "Find References", action: #selector(menuReferences), keyEquivalent: ""))
        }
        items.append(NSMenuItem(title: "Outline", action: #selector(menuOutline), keyEquivalent: ""))
        if menu.numberOfItems > 0 { items.append(.separator()) }
        for (index, item) in items.enumerated() {
            item.target = self
            menu.insertItem(item, at: index)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: codeView)
    }

    @objc private func menuDefinition() {
        guard let context = menuContext, let position = context.position else { return }
        goToDefinition(at: position, anchor: context.anchor, newTile: false)
    }

    @objc private func menuDefinitionNewTile() {
        guard let context = menuContext, let position = context.position else { return }
        goToDefinition(at: position, anchor: context.anchor, newTile: true)
    }

    @objc private func menuReferences() {
        guard let context = menuContext, let position = context.position else { return }
        findReferences(at: position, anchor: context.anchor)
    }

    @objc private func menuOutline() {
        guard let context = menuContext else { return }
        showOutline(anchor: context.anchor)
    }

    // MARK: Plumbing

    /// Runs one explicit action (superseding the previous one and any hover) and shows its
    /// failure where it was asked for: an uninstalled or crashed server is reported, not swallowed.
    private func run(anchor: NSPoint, _ action: @escaping @MainActor (URL, URL) async throws -> Void) {
        cancelPendingHover()
        dismissHover()
        guard let file else { return }
        let root = board.root
        lease(file)
        actionTask?.cancel()
        actionTask = Task { [weak self] in
            do {
                try await action(file, root)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.showMessage((error as? LocalizedError)?.errorDescription ?? "\(error)", anchor: anchor)
            }
        }
    }

    private func showMessage(_ text: String, anchor: NSPoint) {
        present(NavigationPanel.message(text), anchor: anchor)
    }

    private func present(_ panel: NavigationPanel, anchor: NSPoint) {
        guard let codeView else { return }
        panel.show(below: anchor, lineHeight: lineHeight, in: codeView)
        observeTileFrame(codeView)
        self.panel = panel
    }

    /// Panels sit in the canvas document, not the tile, so a moved or resized tile would leave
    /// them behind: dismiss them when the tile's frame changes.
    private func observeTileFrame(_ codeView: NSView) {
        guard !observingTileFrame,
              let tileView = sequence(first: codeView, next: \.superview).first(where: { $0.superview is CanvasDocumentView }) else { return }
        observingTileFrame = true
        NotificationCenter.default.addObserver(self, selector: #selector(dismissAll), name: NSView.frameDidChangeNotification, object: tileView)
    }

    /// Keeps the shown file open in its language server (re-synced before each request) while
    /// this view shows it.
    private func lease(_ file: URL) {
        guard lease?.file != file else { return }
        lease = DocumentLease(file: file, root: board.root)
    }

    /// One app-level monitor for every code view: ⌘/⌥⌘-click and right-click on a host's text
    /// view, and closing a list panel on any click outside it. Hyper (which includes ⌃) is left
    /// to the HyperMonitor.
    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            handle(event) ? nil : event
        }
    }

    /// True when the event was consumed.
    private static func handle(_ event: NSEvent) -> Bool {
        if let panel = NavigationPanel.current, !panel.contains(windowPoint: event.locationInWindow, in: event.window) {
            panel.dismiss()
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.contains(.control), let contentView = event.window?.contentView else { return false }
        let point = contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = contentView.hitTest(point),
              let controller = controllers.allObjects.first(where: { $0.codeView.map { hit.isDescendant(of: $0) } ?? false }),
              let codeView = controller.codeView else { return false }
        switch (event.type, flags) {
        case (.leftMouseDown, [.command]), (.leftMouseDown, [.command, .option]):
            controller.goToDefinition(atViewPoint: codeView.convert(event.locationInWindow, from: nil), newTile: flags.contains(.option))
            return true
        case (.rightMouseDown, []):
            controller.contextMenu(for: event)
            return true
        default:
            return false
        }
    }
}

/// The outline button over a code view: works on the first click into a background window and
/// never takes keyboard focus.
private final class OutlineButton: NSButton {
    /// The button lives inside the tile, so it learns when the tile leaves the window (deleted)
    /// or is hidden (zoomed out, offscreen).
    var onDetach: (() -> Void)?

    convenience init(image: NSImage, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.image = image
        self.target = target
        self.action = action
        imagePosition = .imageOnly
        bezelStyle = .accessoryBarAction
        isBordered = true
        refusesFirstResponder = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onDetach?() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        onDetach?()
    }
}

/// A code view's claim on its file in the language service. Retains and releases go through one
/// ordered stream (a release must never overtake its retain), and dropping the lease — a new
/// file, or the view going away — releases it.
private final class DocumentLease: Sendable {
    let file: URL
    let root: URL

    private static let changes: AsyncStream<(retain: Bool, file: URL, root: URL)>.Continuation = {
        let (stream, continuation) = AsyncStream.makeStream(of: (retain: Bool, file: URL, root: URL).self)
        Task {
            for await change in stream {
                if change.retain {
                    await CodeNavigation.languages.retain(file: change.file, boardRoot: change.root)
                } else {
                    await CodeNavigation.languages.release(file: change.file, boardRoot: change.root)
                }
            }
        }
        return continuation
    }()

    init(file: URL, root: URL) {
        self.file = file
        self.root = root
        Self.changes.yield((true, file, root))
    }

    deinit {
        Self.changes.yield((false, file, root))
    }
}
