import AppKit
import CanvasCore

/// What a code view offers the language features. Implemented by code tiles.
@MainActor
protocol CodeNavigationHost: AnyObject {
    /// Board-relative path of the file shown (the new side of a diff).
    var navigationPath: String { get }
    var navigationTextView: NSTextView { get }
    /// Source position under `point` (in `navigationTextView`'s coordinates): 1-based line,
    /// 0-based UTF-16 column on the current side; nil over deleted rows and gutters.
    func sourcePosition(atViewPoint point: NSPoint) -> (line: Int, character: Int)?
    /// Scrolls a 1-based source line into view.
    func reveal(line: Int)
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
    static let languages = LanguageService()

    /// App quit: end every language server without waiting.
    static func shutdown() {
        languages.terminateAll()
    }

    private static let hoverDelay: TimeInterval = 0.5
    private static let controllers = NSHashTable<CodeNavigation>.weakObjects()
    private static var monitor: Any?

    private weak var host: CodeNavigationHost?
    private weak var textView: NSTextView?
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
    /// Where a context menu was opened, for its actions.
    private var menuContext: (position: (line: Int, character: Int)?, anchor: NSPoint)?
    private var actionTask: Task<Void, Never>?

    init(host: CodeNavigationHost, board: Board, tile: ObjectID) {
        self.host = host
        self.board = board
        self.tile = tile
        let textView = host.navigationTextView
        self.textView = textView
        super.init()
        textView.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        if let clip = textView.enclosingScrollView?.contentView {
            NotificationCenter.default.addObserver(self, selector: #selector(textScrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
        installOutlineButton(textView)
        Self.controllers.add(self)
        Self.installMonitor()
    }

    private var file: URL? {
        host.map { board.absoluteURL($0.navigationPath) }
    }

    // MARK: Hover

    @objc func mouseMoved(with event: NSEvent) {
        guard let textView, event.window === textView.window else { return }
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

    @objc private func textScrolled() {
        cancelPendingHover()
        dismissHover()
    }

    private func cancelPendingHover() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hoverDue), object: nil)
        hoverScheduled = false
        hoverTask?.cancel()
        hoverTask = nil
    }

    @objc private func hoverDue() {
        let still = ProcessInfo.processInfo.systemUptime - lastMove
        guard still >= Self.hoverDelay else {
            perform(#selector(hoverDue), with: nil, afterDelay: Self.hoverDelay - still)
            return
        }
        hoverScheduled = false
        guard let pointer, let textView, let file, let position = position(atWindowPoint: pointer) else { return }
        let anchor = textView.convert(pointer, from: nil)
        let root = board.root
        hoverTask = Task { [weak self] in
            let hover = try? await Self.languages.hover(file: file, boardRoot: root, at: position)
            guard let self, let hover, !Task.isCancelled else { return }
            self.showHover(hover, at: position, anchor: anchor)
        }
    }

    /// Shows hover docs for `position` below `anchor` (in the text view's coordinates).
    func showHover(_ hover: LSPHover, at position: LSPPosition, anchor: NSPoint) {
        guard let textView else { return }
        let panel = NavigationPanel.hover(hover.markdown)
        panel.onPointerExit = { [weak self, weak panel] in
            guard let self, let panel, self.hoverPanel === panel else { return }
            self.dismissHover()
        }
        panel.show(below: anchor, lineHeight: lineHeight, in: textView)
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
        guard let host, let textView else { return nil }
        let local = textView.convert(point, from: nil)
        guard textView.visibleRect.contains(local), let position = host.sourcePosition(atViewPoint: local) else { return nil }
        return LSPPosition(line: position.line - 1, character: position.character)
    }

    private var lineHeight: CGFloat {
        (textView?.font).map { ceil($0.ascender - $0.descender + $0.leading) + 2 } ?? 18
    }

    // MARK: Definition and references

    /// ⌘-click (⌥⌘-click with `newTile`) at a point in the text view.
    func goToDefinition(atViewPoint point: NSPoint, newTile: Bool) {
        guard let host, let position = host.sourcePosition(atViewPoint: point) else { return }
        goToDefinition(at: position, anchor: point, newTile: newTile)
    }

    private func goToDefinition(at position: (line: Int, character: Int), anchor: NSPoint, newTile: Bool) {
        dismissHover()
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
        dismissHover()
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
        let busy = await Self.languages.existingServer(for: file, boardRoot: root)?.activity ?? []
        showMessage(busy.isEmpty ? text : "\(text) yet — \(busy.joined(separator: ", ")) in progress", anchor: anchor)
    }

    /// Same file: re-aim this tile. Another file (or `newTile`): a code tile beside this one.
    private func open(_ location: LSPLocation, newTile: Bool) {
        guard let host else { return }
        let path = boardPath(location.url)
        let start = location.range.start.line + 1
        let range = JSONValue.object(["start": .number(Double(start)), "end": .number(Double(max(start, location.range.end.line + 1)))])
        if !newTile, path == boardPath(board.absoluteURL(host.navigationPath)) {
            _ = try? board.update(tile, props: .object(["range": range]))
        } else {
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

    private func installOutlineButton(_ textView: NSTextView) {
        guard let scroll = textView.enclosingScrollView, let container = scroll.superview else { return }
        let button = OutlineButton(image: NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Outline") ?? NSImage(), target: self, action: #selector(outlineClicked(_:)))
        button.toolTip = "Outline"
        let size: CGFloat = 20
        let top = container.isFlipped ? 4 : container.bounds.height - size - 4
        button.frame = NSRect(x: container.bounds.width - size - 18, y: top, width: size, height: size)
        button.autoresizingMask = container.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        container.addSubview(button, positioned: .above, relativeTo: scroll)
    }

    @objc private func outlineClicked(_ sender: NSButton) {
        guard let textView else { return }
        let anchor = textView.convert(NSPoint(x: sender.frame.maxX, y: sender.frame.midY), from: sender.superview)
        showOutline(anchor: NSPoint(x: max(0, anchor.x - 240), y: anchor.y))
    }

    func showOutline(anchor: NSPoint) {
        dismissHover()
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
        guard let host, let textView else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let position = host.sourcePosition(atViewPoint: point)
        menuContext = (position, point)
        // Build on the view's own menu (copied: AppKit shares it) so its items stay available.
        let menu = (textView.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
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
        NSMenu.popUpContextMenu(menu, with: event, for: textView)
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

    /// Runs one explicit action (superseding the previous) and shows its failure where it was
    /// asked for: an uninstalled or crashed server is reported, not swallowed.
    private func run(anchor: NSPoint, _ action: @escaping @MainActor (URL, URL) async throws -> Void) {
        guard let file else { return }
        let root = board.root
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
        guard let textView else { return }
        panel.show(below: anchor, lineHeight: lineHeight, in: textView)
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
              let controller = controllers.allObjects.first(where: { $0.textView.map { hit.isDescendant(of: $0) } ?? false }),
              let textView = controller.textView else { return false }
        switch (event.type, flags) {
        case (.leftMouseDown, [.command]), (.leftMouseDown, [.command, .option]):
            controller.goToDefinition(atViewPoint: textView.convert(event.locationInWindow, from: nil), newTile: flags.contains(.option))
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
}
