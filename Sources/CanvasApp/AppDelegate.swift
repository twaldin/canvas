import AppKit
import CanvasCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let registry = BoardRegistry(store: BoardStore(directory: AppPaths.boards))
    private lazy var router = ApiRouter(registry: registry)
    private var server: SocketServer?
    private var cmuxServer: SocketServer?
    private lazy var cmux = CmuxRouter(registry: registry, password: AppPaths.cmuxPassword)
    private var controllers: [BoardID: CanvasWindowController] = [:]
    private var terminationSignal: DispatchSourceSignal?
    private let notifier = AgentNotifier()
    private lazy var hyper = HyperMonitor { [weak self] window in
        self?.controllers.values.first { $0.window === window }?.canvas
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMenu()
        // `kill <pid>` (scripts, logout) quits through the normal path so boards are flushed.
        // The signal is received off the main queue and handed to the main run loop in every
        // mode, because an app-modal session (NSAlert.runModal, NSOpenPanel) doesn't drain the
        // main queue; sheets and modal sessions are ended first since either one holds up
        // `terminate`.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        // `@Sendable`: written inside this @MainActor method, the handler would otherwise be
        // inferred main-actor isolated, and Swift's runtime check traps when it runs on the
        // global queue (every `kill <pid>` crashed instead of quitting, losing unflushed boards).
        termination.setEventHandler { @Sendable in
            let main = CFRunLoopGetMain()
            let modes = [CFRunLoopMode.commonModes.rawValue, RunLoop.Mode.modalPanel.rawValue as CFString, RunLoop.Mode.eventTracking.rawValue as CFString] as CFArray
            CFRunLoopPerformBlock(main, modes) {
                MainActor.assumeIsolated { AppDelegate.terminateNow() }
            }
            CFRunLoopWakeUp(main)
        }
        termination.resume()
        terminationSignal = termination
        DevInput.install()
        // Canvas's own leftovers: dead sessions' zmx logs, read Ghostty configs, old renders.
        Housekeeping.pruneAtLaunch()
        if let url = AppPaths.asset(DrawingStyle.fontAsset) { DrawingStyle.registerFonts(url) }
        registry.onEvent = { [weak self] board, event in
            self?.controllers[board.id]?.apply(event)
            self?.notifier.observe(event, on: board)
        }
        // Every delete of a terminal (UI close, API, batch, undo/redo) ends its zmx session.
        registry.onTerminalsEnded = { _, tiles in
            for tile in tiles { TerminalTile.killSession(tile: tile) }
        }
        // object.measure, size: "fit", and layout.check lay HTML pages out in WebKit.
        ObjectMeasure.html = { props, width, root in try await HtmlTile.measure(props: props, width: width, root: root) }
        notifier.onOpen = { [weak self] board, tile in
            guard let controller = self?.controllers[board] else { return }
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            controller.canvas.focus(tile: tile)
        }
        notifier.install()
        router.submitToTerminal = { [weak self] board, tile, text in
            guard let terminal = self?.controllers[board.id]?.canvas.tiles[tile]?.content as? TerminalTile else { return false }
            return await terminal.submit(text)
        }
        router.terminalStatus = { [weak self] board, tile in
            guard let terminal = self?.controllers[board.id]?.canvas.tiles[tile]?.content as? TerminalTile else { return TerminalStatus() }
            terminal.refreshProgram()
            // Gemini CLI pads its title to a fixed width.
            return TerminalStatus(title: terminal.oscTitle?.trimmingCharacters(in: .whitespaces), program: terminal.program, lastCommand: terminal.lastCommand)
        }
        router.tmuxPane = { [weak self] board, tile in
            guard let terminal = self?.controllers[board.id]?.canvas.tiles[tile]?.content as? TerminalTile else { return nil }
            return await terminal.tmuxPane()
        }
        router.readTerminalBlock = { [weak self] board, tile in
            guard let terminal = self?.controllers[board.id]?.canvas.tiles[tile]?.content as? TerminalTile else {
                throw ApiRouter.Failure("unavailable", "terminal \(tile) isn't shown in a window")
            }
            return try terminal.lastBlock()
        }
        router.pageReport = { [weak self] board, tile in
            guard let browser = self?.controllers[board.id]?.canvas.tiles[tile]?.content as? BrowserTile else { return nil }
            return await browser.pageReport()
        }
        router.noteExcerpts = { [weak self] board, tile in
            guard let note = self?.controllers[board.id]?.canvas.tiles[tile]?.content as? NoteTile else { return nil }
            return await note.resolvedExcerpts()
        }
        router.codeRangeStatus = { [weak self] board, tile in
            guard let code = self?.controllers[board.id]?.canvas.tiles[tile]?.content as? CodeTile else { return nil }
            return await code.rangeStatus()
        }
        router.reloadBrowser = { [weak self] board, tile, caller, timeoutMs in
            guard let browser = self?.controllers[board.id]?.canvas.tiles[tile]?.content as? BrowserTile else {
                throw ApiRouter.Failure("unavailable", "browser tile \(tile) is not open in a window")
            }
            do {
                return try await browser.reloadPage(driver: caller, timeoutMs: timeoutMs)
            } catch let error as CmuxError {
                throw ApiRouter.Failure(error.code, error.message)
            }
        }
        router.snapshotBoard = { [weak self] board, format in await self?.controllers[board.id]?.snapshot(format: format) }
        router.renderView = { [weak self] board, request, format in
            guard let canvas = self?.controllers[board.id]?.canvas else { throw ApiRouter.Failure("unavailable", "board \(board.id) has no window") }
            return try await canvas.render(request, format: format)
        }
        router.viewState = { [weak self] board in self?.controllers[board.id]?.canvas.viewState }
        router.openBoard = { [weak self, registry] root, select in
            self?.open(root: root, select: select) ?? registry.open(root: root)
        }
        router.readTerminal = { [weak self] board, tile, lines in
            // Rows the terminal soft-wrapped join when its tile knows its width.
            let columns = (self?.controllers[board.id]?.canvas.tiles[tile]?.content as? TerminalTile)?.columns
            // A blocking subprocess read: keep it on GCD so it can't park Swift's cooperative
            // threads, which the socket servers' request tasks need.
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: TerminalTile.history(session: TerminalTile.sessionName(tile), lines: lines, columns: columns))
                }
            }
        }
        let router = router
        let server = SocketServer(path: AppPaths.apiSocket) { request, connection in
            await router.handle(request, connection: connection)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("Canvas: cannot listen on \(AppPaths.apiSocket): \(error)")
        }
        cmux.perform = { [weak self] board, object, command, driver in
            guard let tile = self?.controllers[board.id]?.canvas.tiles[object.id]?.content as? BrowserTile else {
                throw CmuxError("unavailable", "browser surface \(object.id) is not open in a window")
            }
            return try await tile.perform(command, driver: driver)
        }
        let cmux = cmux
        let cmuxServer = SocketServer(path: AppPaths.cmuxSocket, acceptsTextLines: true) { request, connection in
            await cmux.handle(request, connection: connection)
        }
        do {
            try cmuxServer.start()
            self.cmuxServer = cmuxServer
        } catch {
            NSLog("Canvas: cannot listen on \(AppPaths.cmuxSocket): \(error)")
        }
        hyper.install()
        let saved = Self.savedOpenBoards()
        let initial = open(root: Self.initialRoot())
        // The other boards that were open as tabs come back behind the initial one.
        for root in saved where root.standardizedFileURL != initial.root.standardizedFileURL && BoardStore.isDirectory(root.path) {
            open(root: root, select: false)
        }
        // Testing on a shared machine: CANVAS_NO_ACTIVATE=1 keeps the app from taking focus.
        if ProcessInfo.processInfo.environment["CANVAS_NO_ACTIVATE"] != "1" {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Quit even while a sheet or app-modal dialog is up: cancel them, then terminate once the
    /// modal loop has unwound.
    private static func terminateNow() {
        for window in NSApp.windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        }
        if NSApp.modalWindow != nil {
            NSApp.abortModal()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        registry.store.flush(Array(registry.boards.values))
        server?.stop()
        cmuxServer?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting closes every window; those closes mustn't erase the tabs to reopen.
        terminating = true
        return CodeNavigation.terminateServers()
    }

    private var terminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Opens a directory's board as a tab of the frontmost board window (its own window when it's
    /// the first). `select` brings its tab forward; the API's `board.open` leaves the user's
    /// current tab showing unless asked.
    @discardableResult
    func open(root: URL, select: Bool = true) -> Board {
        let board = registry.open(root: root)
        let controller = controllers[board.id] ?? CanvasWindowController(board: board, registry: registry)
        controllers[board.id] = controller
        controller.onClose = { [weak self, weak controller] in self?.saveOpenBoards(closing: controller?.window) }
        guard let window = controller.window else { return board }
        defer { saveOpenBoards() }
        let noActivate = ProcessInfo.processInfo.environment["CANVAS_NO_ACTIVATE"] == "1"
        if !isShown(window), let host = tabHost(excluding: window) {
            let front = host.tabGroup?.selectedWindow ?? host
            // `addTabbedWindow` onto a minimized window shows the new one by itself on the
            // current Space; the group takes it as a hidden tab.
            if host.isMiniaturized, let group = host.tabGroup { group.addWindow(window) } else { host.addTabbedWindow(window, ordered: .above) }
            if !select { window.tabGroup?.selectedWindow = front }
        } else if !isShown(window) {
            if noActivate { window.orderBack(nil) } else { controller.showWindow(nil) }
            return board
        }
        guard select else { return board }
        // Selecting a tab of a minimized group also detaches it onto the current Space: bring the
        // group back first (the user asked to see this board). An instance that never activates
        // leaves the tab waiting in the minimized group.
        if let minimized = window.tabGroup?.windows.first(where: \.isMiniaturized) {
            if noActivate { return board }
            minimized.deminiaturize(nil)
        }
        window.tabGroup?.selectedWindow = window
        if !noActivate { window.makeKeyAndOrderFront(nil) }
        return board
    }

    /// A tab that isn't selected is ordered out and a minimized window isn't visible, so "shown"
    /// means visible, minimized, or in a tab group.
    private func isShown(_ window: NSWindow) -> Bool {
        window.isVisible || window.isMiniaturized || (window.tabGroup?.windows.count ?? 0) > 1
    }

    /// The board window new boards join as tabs: the key one, else any on screen, else a
    /// minimized one (a board opened while the window is in the Dock joins it there rather than
    /// opening a window of its own on the user's current Space).
    private func tabHost(excluding window: NSWindow) -> NSWindow? {
        let windows = controllers.values.compactMap(\.window).filter { $0 !== window && ($0.isVisible || $0.isMiniaturized) }
        return windows.first(where: \.isKeyWindow) ?? windows.first(where: \.isVisible) ?? windows.first
    }

    /// Records the shown boards' roots in tab order (AppPaths.openBoards) for the next launch.
    private func saveOpenBoards(closing: NSWindow? = nil) {
        guard !terminating else { return }
        let shown = controllers.values.filter { $0.window.map { $0 !== closing && isShown($0) } ?? false }
        let order = shown.first?.window?.tabbedWindows ?? []
        let roots = shown.sorted { lhs, rhs in
            (order.firstIndex { $0 === lhs.window } ?? .max) < (order.firstIndex { $0 === rhs.window } ?? .max)
        }.map(\.board.root.path)
        guard let data = try? JSONEncoder().encode(roots) else { return }
        try? data.write(to: AppPaths.openBoards, options: .atomic)
    }

    private static func savedOpenBoards() -> [URL] {
        guard let data = try? Data(contentsOf: AppPaths.openBoards), let roots = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return roots.map { URL(fileURLWithPath: $0) }
    }

    /// CANVAS_ROOT, else the first non-flag argument, else the working directory (home when launched from Finder).
    static func initialRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let root = env["CANVAS_ROOT"] { return URL(fileURLWithPath: root) }
        if let argument = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) { return URL(fileURLWithPath: argument) }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd == "/" ? NSHomeDirectory() : cwd)
    }

    private var keyController: CanvasWindowController? {
        controllers.values.first { $0.window?.isKeyWindow == true } ?? controllers.values.first
    }

    @objc func newTerminal(_ sender: Any?) { keyController?.newTerminal(sender) }
    @objc func newBrowserTile(_ sender: Any?) {
        guard let controller = keyController, let window = controller.window else { return }
        BrowserTile.promptForNew(in: window) { [weak controller] url in
            controller?.canvas.openForUser(.browser, props: .object(["url": .string(url.absoluteString)]))
        }
    }
    @objc func openCodeTile(_ sender: Any?) { keyController?.openCodeTile(sender) }
    /// An empty note in view, editing (`CanvasView.openForUser`).
    @objc func newNote(_ sender: Any?) {
        keyController?.canvas.openForUser(.note, props: .object(["markdown": .string("")]))
    }

    @objc func newHtmlTile(_ sender: Any?) {
        keyController?.canvas.openForUser(.html, props: .object(["html": .string(HtmlKit.emptyTemplate), "title": .string("HTML")]))
    }
    @objc func zoomToActual(_ sender: Any?) { keyController?.zoomToActual(sender) }
    @objc func zoomOut(_ sender: Any?) { keyController?.zoomOut(sender) }
    @objc func zoomIn(_ sender: Any?) { keyController?.zoomIn(sender) }
    @objc func zoomToFit(_ sender: Any?) { keyController?.zoomToFit(sender) }
    @objc func showNavigator(_ sender: Any?) { keyController?.showNavigator(sender) }
    @objc func toggleBasics(_ sender: Any?) { keyController?.toggleBasics(sender) }
    @objc func toggleCanvasChrome(_ sender: Any?) { keyController?.toggleCanvasChrome(sender) }
    @objc func toggleLassoSelection(_ sender: Any?) { keyController?.toggleLassoSelection(sender) }
    @objc func exitGroup(_ sender: Any?) { keyController?.exitGroup(sender) }
    @objc func undoCanvas(_ sender: Any?) { keyController?.undoCanvas(sender) }
    @objc func redoCanvas(_ sender: Any?) { keyController?.redoCanvas(sender) }
    @objc func deleteSelection(_ sender: Any?) { keyController?.deleteSelection(sender) }
    @objc func selectAll(_ sender: Any?) { keyController?.selectAllObjects(sender) }
    @objc func groupSelection(_ sender: Any?) { keyController?.groupSelection(sender) }
    @objc func ungroupSelection(_ sender: Any?) { keyController?.ungroupSelection(sender) }
    @objc func bringToFront(_ sender: Any?) { keyController?.bringToFront(sender) }
    @objc func sendToBack(_ sender: Any?) { keyController?.sendToBack(sender) }
    @objc func pasteMentions(_ sender: Any?) { keyController?.pasteMentions(sender) }
    @objc func mentionCurrent(_ sender: Any?) { keyController?.mentionCurrent(sender) }
    @objc func goToNextNeedsYou(_ sender: Any?) { keyController?.goToNextNeedsYou(sender) }
    @objc func navigateBack(_ sender: Any?) { keyController?.navigateBack(sender) }
    @objc func navigateForward(_ sender: Any?) { keyController?.navigateForward(sender) }
    @objc func reviewChanges(_ sender: Any?) { keyController?.reviewChanges(sender) }
    @objc func reviewBranch(_ sender: Any?) { keyController?.reviewBranch(sender) }
    @objc func clearAttentionMarkers(_ sender: Any?) { keyController?.clearAttentionMarkers(sender) }
    @objc func toggleFollowFiles(_ sender: Any?) { keyController?.toggleFollowFiles(sender) }
    @objc func scaleSelection(_ sender: Any?) { keyController?.scaleSelection(sender) }
    @objc func scaleBigger(_ sender: Any?) { keyController?.scaleBigger(sender) }
    @objc func scaleSmaller(_ sender: Any?) { keyController?.scaleSmaller(sender) }
    @objc func copyObjectIDs(_ sender: Any?) { keyController?.copyObjectIDs(sender) }
    @objc func enterGroup(_ sender: Any?) { keyController?.enterGroup(sender) }
    @objc func goToDefinition(_ sender: Any?) { keyController?.goToDefinition(sender) }
    @objc func openDefinitionInNewTile(_ sender: Any?) { keyController?.openDefinitionInNewTile(sender) }
    @objc func findReferences(_ sender: Any?) { keyController?.findReferences(sender) }
    @objc func showOutline(_ sender: Any?) { keyController?.showOutline(sender) }
    @objc func leaveTile(_ sender: Any?) { keyController?.leaveTile(sender) }
    @objc func copyAsImage(_ sender: Any?) { keyController?.copyAsImage(sender) }
    @objc func saveAsPNG(_ sender: Any?) { keyController?.saveAsPNG(sender) }
    @objc func saveHTMLTile(_ sender: Any?) { keyController?.saveHTMLTile(sender) }
    @objc func openHTMLTileInBrowser(_ sender: Any?) { keyController?.openHTMLTileInBrowser(sender) }
    @objc func copyNoteAsMarkdown(_ sender: Any?) { keyController?.copyNoteAsMarkdown(sender) }
    @objc func saveNoteAsMarkdown(_ sender: Any?) { keyController?.saveNoteAsMarkdown(sender) }
    @objc func showWebInspector(_ sender: Any?) { keyController?.showWebInspector(sender) }
    @objc func snapshotPage(_ sender: Any?) { keyController?.snapshotPage(sender) }
    @objc func clearBrowsingData(_ sender: Any?) {
        guard let controller = keyController, let window = controller.window else { return }
        BrowserProfile.confirmClear(in: window) { [weak controller] in controller?.canvas.showNotice("Browsing data cleared") }
    }

    /// The tab bar's + button: open another board as a tab.
    @objc func newWindowForTab(_ sender: Any?) { openBoard(sender) }

    /// One canvas per directory: choosing a folder opens (or brings forward) its board. A sheet,
    /// not `runModal`: a modal run loop would stall every socket request until the user answers.
    @objc func openBoard(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Open Board"
        panel.directoryURL = keyController?.board.root
        let chosen: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(root: url)
        }
        if let window = keyController?.window {
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            panel.begin(completionHandler: chosen)
        }
    }

    static func makeMenu() -> NSMenu {
        let main = NSMenu()
        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        submenu("Canvas", [
            // Every browser tile's cookies, storage and caches (`BrowserProfile`), after a sheet.
            item("Clear Browsing Data…", #selector(clearBrowsingData(_:)), ""),
            .separator(),
            item("Quit Canvas", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("New Terminal", #selector(newTerminal(_:)), "t"),
            item("New Note", #selector(newNote(_:)), "n"),
            // Shifted items use the uppercase key: a lowercase key with a Shift mask also matches
            // the plain ⌘ key (⌘O opened Open Board, ⌘B New Browser Tile).
            item("New Browser Tile…", #selector(newBrowserTile(_:)), "B", [.command, .shift]),
            item("Open File as Code Tile…", #selector(openCodeTile(_:)), "o"),
            item("Open Board…", #selector(openBoard(_:)), "O", [.command, .shift]),
            item("New HTML Tile", #selector(newHtmlTile(_:)), "H", [.command, .shift]),
            item("Review Changes", #selector(reviewChanges(_:)), "R", [.command, .shift]),
            item("Review Branch", #selector(reviewBranch(_:)), ""),
            .separator(),
            item("Export Selection as PNG…", #selector(saveAsPNG(_:)), "E", [.command, .shift]),
            item("Save HTML Tile as HTML…", #selector(saveHTMLTile(_:)), ""),
            item("Open HTML Tile in Browser", #selector(openHTMLTileInBrowser(_:)), ""),
            item("Save Note as Markdown…", #selector(saveNoteAsMarkdown(_:)), ""),
            // The focused or selected browser tile's page, frozen as an image tile beside it.
            item("Snapshot Page to Image", #selector(snapshotPage(_:)), ""),
            .separator(),
            // The board window takes ⌘W first to close the selection or the focused terminal
            // (CanvasWindowController.handleKeyEquivalent); with neither, the tab or window closes.
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Undo", #selector(undoCanvas(_:)), "z"),
            item("Redo", #selector(redoCanvas(_:)), "Z", [.command, .shift]),
            .separator(),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Copy as Image", #selector(copyAsImage(_:)), "C", [.command, .shift]),
            item("Copy Note as Markdown", #selector(copyNoteAsMarkdown(_:)), ""),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            item("Delete Selection", #selector(deleteSelection(_:)), "\u{8}"),
            .separator(),
            // Hyper-V: no shell, TUI, or Ghostty default binding uses all four modifiers.
            item("Paste Mentions into Terminal", #selector(pasteMentions(_:)), "v", [.control, .option, .shift, .command]),
            // ⇧⌘M: no shell or TUI sees ⌘, Ghostty binds nothing to it, and the board window
            // takes it ahead of a focused terminal (CanvasWindowController.handleKeyEquivalent).
            item("Mention", #selector(mentionCurrent(_:)), "M", [.command, .shift]),
        ])
        // Scale: the selection, else the tile holding the keyboard (`CanvasView.scaleTargets`).
        // ⌃⌘ chords: ⌥⌘= / ⌥⌘- are macOS Zoom's (Accessibility), which the people who need
        // bigger tiles use; Ghostty's ⌃⌘= (equalize splits) has no splits here, and a focused
        // terminal's menu shortcuts beat its bindings (CanvasWindowController.handleKeyEquivalent).
        let scale = NSMenuItem(title: "Scale", action: nil, keyEquivalent: "")
        scale.submenu = NSMenu(title: "Scale")
        scale.submenu?.addItem(item("Bigger", #selector(scaleBigger(_:)), "=", [.control, .command]))
        scale.submenu?.addItem(item("Smaller", #selector(scaleSmaller(_:)), "-", [.control, .command]))
        scale.submenu?.addItem(.separator())
        for preset in ObjectScale.presets {
            let percent = Int((preset * 100).rounded())
            let item = item("\(percent)%", #selector(scaleSelection(_:)), "")
            item.tag = percent
            scale.submenu?.addItem(item)
        }
        scale.submenu?.addItem(.separator())
        let actual = item("Actual Size", #selector(scaleSelection(_:)), "0", [.control, .command])
        actual.tag = 100
        scale.submenu?.addItem(actual)
        submenu("Object", [
            item("Group", #selector(groupSelection(_:)), "g"),
            item("Ungroup", #selector(ungroupSelection(_:)), "G", [.command, .shift]),
            item("Enter Group", #selector(enterGroup(_:)), ""),
            .separator(),
            // "}" and "{": ⇧⌘] and ⇧⌘[ as the key produces them. "]" and "[" with a Shift mask
            // matched the plain ⌘] and ⌘[ (Forward and Back) and never the shifted chords.
            item("Bring to Front", #selector(bringToFront(_:)), "}", [.command, .shift]),
            item("Send to Back", #selector(sendToBack(_:)), "{", [.command, .shift]),
            scale,
            .separator(),
            // The focused terminal's, else the selected one's (the context menu's toggle).
            item("Follow Files", #selector(toggleFollowFiles(_:)), ""),
            item("Copy Object ID", #selector(copyObjectIDs(_:)), ""),
            .separator(),
            // ⌘W itself is File ▸ Close's (the board window takes it first for the selection).
            item("Close Selection", #selector(deleteSelection(_:)), ""),
        ])
        // The focused code tile's, else the selected one's, at its selection or the first name on
        // its first line (CodeTile.navigate). ⌃⌘ chords: no shell sees ⌘, and Ghostty binds none.
        submenu("Code", [
            item("Go to Definition", #selector(goToDefinition(_:)), "j", [.control, .command]),
            item("Open Definition in New Tile", #selector(openDefinitionInNewTile(_:)), "j", [.control, .option, .command]),
            item("Find References", #selector(findReferences(_:)), "r", [.control, .command]),
            item("Outline", #selector(showOutline(_:)), "o", [.control, .command]),
        ])
        let lasso = item("Lasso Selection", #selector(toggleLassoSelection(_:)), "")
        lasso.state = CanvasView.lassoSelection ? .on : .off
        submenu("View", [
            // ⌘P, not ⌘K: Ghostty binds ⌘K (clear screen) and terminal tiles take it first.
            item("Go to…", #selector(showNavigator(_:)), "p"),
            // ⌘J: no shell sees ⌘, and Ghostty binds nothing to it.
            item("Go to Next Needs-You", #selector(goToNextNeedsYou(_:)), "j"),
            // ⌘Esc: Esc belongs to a terminal's program, so this is the way out of one (and of
            // any tile); the board window takes it before Ghostty's keybinds. No shell sees ⌘.
            item("Leave Tile", #selector(leaveTile(_:)), "\u{1b}"),
            // ⌘[ / ⌘] as in Xcode, PyCharm and Safari: the board window takes them ahead of a
            // terminal (Ghostty's go to split has no splits here); a page with the keyboard goes
            // back itself. Send to Back and Bring to Front are ⇧⌘[ / ⇧⌘].
            item("Back", #selector(navigateBack(_:)), "["),
            item("Forward", #selector(navigateForward(_:)), "]"),
            .separator(),
            item("Actual Size", #selector(zoomToActual(_:)), "0"),
            item("Zoom In", #selector(zoomIn(_:)), "="),
            item("Zoom Out", #selector(zoomOut(_:)), "-"),
            item("Zoom to Fit", #selector(zoomToFit(_:)), "9"),
            .separator(),
            item("Clear Attention Markers", #selector(clearAttentionMarkers(_:)), ""),
            // ⌥⌘I as in Safari's Develop menu: the focused or selected browser tile's page.
            item("Show Web Inspector", #selector(showWebInspector(_:)), "i", [.option, .command]),
            // Presenting: toolbar, tray, selection rings, author marks, code headers, markers.
            // ⌥⌘T as AppKit's Show/Hide Toolbar; Ghostty binds nothing to it.
            item("Hide Canvas Chrome", #selector(toggleCanvasChrome(_:)), "t", [.option, .command]),
            lasso,
            item("Exit Group", #selector(exitGroup(_:)), ""),
        ])
        // AppKit lists the board windows and tabs here (and the tab commands) itself.
        NSApp.windowsMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        // The Help menu gets AppKit's menu search (⌘?), which finds every item above, and the
        // legend of what the canvas shows (`BasicsPanel`), ⌥⌘/ beside that search's ⌘?.
        NSApp.helpMenu = submenu("Help", [
            item("Canvas Basics", #selector(toggleBasics(_:)), "/", [.option, .command]),
        ])
        return main
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Menu items that don't apply now are disabled (the board window decides).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        keyController?.validate(item) ?? false
    }
}
