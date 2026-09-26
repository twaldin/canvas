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
    private lazy var hyper = HyperMonitor { [weak self] window in
        self?.controllers.values.first { $0.window === window }?.canvas
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMenu()
        // `kill <pid>` (scripts, logout) quits through the normal path so boards are flushed.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        terminationSignal = termination
        DevInput.install()
        registry.onEvent = { [weak self] board, event in
            self?.controllers[board.id]?.apply(event)
        }
        router.submitToTerminal = { [weak self] board, tile, text in
            guard let terminal = self?.controllers[board.id]?.canvas.tiles[tile]?.content as? TerminalTile else { return false }
            return terminal.paste(text, submit: true)
        }
        router.snapshotBoard = { [weak self] board in self?.controllers[board.id]?.snapshotPNG() }
        router.objectImage = { [weak self] board, id in
            guard let image = self?.controllers[board.id]?.canvas.tiles[id]?.content.snapshot(),
                  let tiff = image.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
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

    func applicationWillTerminate(_ notification: Notification) {
        registry.store.flush(Array(registry.boards.values))
        server?.stop()
        cmuxServer?.stop()
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
    @objc func zoomToActual(_ sender: Any?) { keyController?.zoomToActual(sender) }
    @objc func zoomOut(_ sender: Any?) { keyController?.zoomOut(sender) }
    @objc func closeSelected(_ sender: Any?) { keyController?.closeSelected(sender) }

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
            item("New Browser Tile…", #selector(newBrowserTile(_:)), "b", [.command, .shift]),
            item("Open File as Code Tile…", #selector(openCodeTile(_:)), "o"),
            item("Close Selected Tiles", #selector(closeSelected(_:)), "w", [.command, .shift]),
        ])
        submenu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("View", [
            item("Actual Size", #selector(zoomToActual(_:)), "0"),
            item("Zoom Out", #selector(zoomOut(_:)), "-"),
        ])
        return main
    }
}
