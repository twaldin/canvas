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
        DrawingStyle.registerFonts()
        registry.onEvent = { [weak self] board, event in
            self?.controllers[board.id]?.apply(event)
            self?.notifier.observe(event, on: board)
        }
        notifier.onOpen = { [weak self] board, tile in
            guard let controller = self?.controllers[board] else { return }
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            controller.canvas.focus(tile: tile)
        }
        notifier.install()
        router.submitToTerminal = { [weak self] board, tile, text in
            guard let terminal = self?.controllers[board.id]?.canvas.tiles[tile]?.content as? TerminalTile else { return false }
            return terminal.paste(text, submit: true)
        }
        router.snapshotBoard = { [weak self] board, format in self?.controllers[board.id]?.snapshot(format: format) }
        router.renderView = { [weak self] board, request, format in
            guard let canvas = self?.controllers[board.id]?.canvas else { throw ApiRouter.Failure("unavailable", "board \(board.id) has no window") }
            return try await canvas.render(request, format: format)
        }
        router.viewState = { [weak self] board in self?.controllers[board.id]?.canvas.viewState }
        router.raiseAttention = { [weak self] board, id, message in
            self?.controllers[board.id]?.canvas.raiseAttention(id, message: message)
        }
        router.clearAttention = { [weak self] board, id in
            self?.controllers[board.id]?.canvas.clearAttention(id) ?? false
        }
        router.readTerminal = { _, tile, lines in
            // A blocking subprocess read: keep it on GCD so it can't park Swift's cooperative
            // threads, which the socket servers' request tasks need.
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: TerminalTile.history(session: TerminalTile.sessionName(tile), lines: lines))
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
        cmux.perform = { [weak self] board, object, command in
            guard let tile = self?.controllers[board.id]?.canvas.tiles[object.id]?.content as? BrowserTile else {
                throw CmuxError("unavailable", "browser surface \(object.id) is not open in a window")
            }
            return try await tile.perform(command)
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
        open(root: Self.initialRoot())
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
        CodeNavigation.terminateServers()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func open(root: URL) {
        let board = registry.open(root: root)
        let controller = controllers[board.id] ?? CanvasWindowController(board: board, registry: registry)
        controllers[board.id] = controller
        if ProcessInfo.processInfo.environment["CANVAS_NO_ACTIVATE"] == "1" {
            controller.window?.orderBack(nil)
        } else {
            controller.showWindow(nil)
        }
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
        BrowserTile.promptForNew(on: controller.board, in: window)
    }
    @objc func openCodeTile(_ sender: Any?) { keyController?.openCodeTile(sender) }
    /// An empty note at the viewport center; it shows a double-click-to-edit placeholder.
    @objc func newNote(_ sender: Any?) {
        keyController?.board.create(type: .note, props: .object(["markdown": .string("")]))
    }

    @objc func newHtmlTile(_ sender: Any?) {
        keyController?.board.create(type: .html, props: .object(["html": .string(HtmlKit.emptyTemplate), "title": .string("HTML")]))
    }
    @objc func zoomToActual(_ sender: Any?) { keyController?.zoomToActual(sender) }
    @objc func zoomOut(_ sender: Any?) { keyController?.zoomOut(sender) }
    @objc func zoomToFit(_ sender: Any?) { keyController?.zoomToFit(sender) }
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
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        submenu("Canvas", [item("Quit Canvas", #selector(NSApplication.terminate(_:)), "q")])
        submenu("File", [
            item("New Terminal", #selector(newTerminal(_:)), "t"),
            item("New Note", #selector(newNote(_:)), "n"),
            item("New Browser Tile…", #selector(newBrowserTile(_:)), "b", [.command, .shift]),
            item("Open Board…", #selector(openBoard(_:)), "o", [.command, .shift]),
            item("Open File as Code Tile…", #selector(openCodeTile(_:)), "o"),
            item("New HTML Tile", #selector(newHtmlTile(_:)), "h", [.command, .shift]),
        ])
        submenu("Edit", [
            item("Undo", #selector(undoCanvas(_:)), "z"),
            item("Redo", #selector(redoCanvas(_:)), "Z", [.command, .shift]),
            .separator(),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            item("Delete Selection", #selector(deleteSelection(_:)), "\u{8}"),
        ])
        submenu("Object", [
            item("Group", #selector(groupSelection(_:)), "g"),
            item("Ungroup", #selector(ungroupSelection(_:)), "G", [.command, .shift]),
            .separator(),
            item("Bring to Front", #selector(bringToFront(_:)), "]", [.command, .shift]),
            item("Send to Back", #selector(sendToBack(_:)), "[", [.command, .shift]),
        ])
        let lasso = item("Lasso Selection", #selector(toggleLassoSelection(_:)), "")
        lasso.state = CanvasView.lassoSelection ? .on : .off
        submenu("View", [
            item("Actual Size", #selector(zoomToActual(_:)), "0"),
            item("Zoom Out", #selector(zoomOut(_:)), "-"),
            item("Zoom to Fit", #selector(zoomToFit(_:)), "9"),
            .separator(),
            lasso,
            item("Exit Group", #selector(exitGroup(_:)), ""),
        ])
        return main
    }
}
