import AppKit
import CanvasCore
import WebKit

/// A web page on the canvas. Every browser tile shares WebKit's default website data store, so
/// they are one browser profile (cookies, logins) with separate screens. (Since macOS 12 WebKit
/// ignores process pools and all web views share one, so there is no pool to configure.)
///
/// The web view is created the first time the tile is live and detached (left with a snapshot)
/// while it isn't. After `releaseDelay` detached it is released entirely and later rebuilt from
/// `props.url`. The cmux subset (BrowserAutomation.swift) can wake it without making it live;
/// while an agent drives the page it stays visible to WebKit (see `markDriven`).
@MainActor
final class BrowserTile: NSView, TileContent {
    static let chromeHeight: CGFloat = 32
    /// Cap on the cached page image (zoomed-out cards, `view.snapshot` covers), in pixels.
    static let snapshotPixelBudget: CGFloat = 1_500_000
    static let releaseDelay: TimeInterval = 600
    /// Minimum spacing between background snapshot refreshes of a busy page.
    static let refreshInterval: TimeInterval = 1
    /// How long a page counts as agent-driven after the last cmux command.
    static let drivenIdle: TimeInterval = 60
    /// Longest a command waits for a page it just made visible to present a frame.
    static let revealWait: TimeInterval = 0.5
    /// How long a released web view outlives its release (see `release`).
    static let closeDelay: TimeInterval = 2

    let objectID: ObjectID
    let board: Board
    private(set) var object: CanvasObject
    private(set) var webView: WKWebView?
    private let chrome = BrowserChrome()
    /// Covers the web view while `view.snapshot` renders (WebKit draws outside `cacheDisplay`).
    private let cover = NSImageView()
    private var cachedImage: NSImage?
    private var isLive = true
    private var releaseTimer: Timer?
    /// Set while an agent drives the page; fires `drivenIdle` after the last command.
    private var drivenTimer: Timer?
    private var observations: [NSKeyValueObservation] = []
    private var refreshScheduled = false
    private var lastRefresh = Date.distantPast
    private var readyWaiters: [@MainActor () -> Void] = []

    /// Navigations this tile started that haven't finished or failed (for load-state waits).
    var pendingNavigations: [WKNavigation] = []
    /// Navigations (ours or the page's) whose new document hasn't replaced the current one yet;
    /// until then the current document's ready state says nothing about the destination.
    var uncommittedNavigations: [WKNavigation] = []
    /// Automation waits parked until the page changes (navigation, DOM activity) or time runs out.
    private var changeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Latest Hyper-hover answer, and the point whose answer is still wanted.
    private var hover: (point: CGPoint, element: WebMentions.Element)?
    private var hoverWanted: CGPoint?
    private var hoverInFlight = false

    init(object: CanvasObject, board: Board) {
        objectID = object.id
        self.board = board
        self.object = object
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        chrome.autoresizingMask = [.width]
        chrome.onBack = { [weak self] in self?.webView?.goBack() }
        chrome.onForward = { [weak self] in self?.webView?.goForward() }
        chrome.onSubmit = { [weak self] text in self?.submitAddress(text) }
        chrome.onReload = { [weak self] in
            guard let self else { return }
            if let webView = self.webView, webView.isLoading { return webView.stopLoading() }
            self.track(self.ensureWebView().reload())
        }
        chrome.setAddress(object.props["url"]?.string ?? "")
        addSubview(chrome)
        cover.imageScaling = .scaleAxesIndependently
        cover.autoresizingMask = [.width, .height]
        cover.isHidden = true
        addSubview(cover)
        layoutParts()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    private var pageFrame: NSRect {
        NSRect(x: 0, y: Self.chromeHeight, width: bounds.width, height: max(0, bounds.height - Self.chromeHeight))
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutParts()
    }

    /// A detached web view still gets the tile's size, so pages lay out as they will be seen.
    private func layoutParts() {
        chrome.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.chromeHeight)
        cover.frame = pageFrame
        webView?.frame = pageFrame
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            // Closed or its canvas went away: nothing will show or drive this page again.
            release()
            return
        }
        // A driven page moves to the stage while its window is off screen (minimized, a
        // background tab, the app hidden) and back when it returns.
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(self, selector: #selector(windowVisibilityChanged), name: name, object: window)
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(self, selector: #selector(windowVisibilityChanged), name: name, object: NSApp)
        }
        // The frame view starts out live and only reports changes, and the canvas decides
        // liveness on the next main-queue pass; look after that pass so offscreen tiles never load.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isLive, self.window != nil else { return }
                    self.attach()
                }
            }
        }
    }

    // MARK: Web view lifecycle

    @discardableResult
    func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let view = makeWebView()
        load(object.props["url"]?.string ?? "about:blank")
        return view
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        WebMentions.install(on: configuration)
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: BrowserScripts.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: BrowserScripts.world))
        controller.add(PageMessages(tile: self), contentWorld: BrowserScripts.world, name: BrowserScripts.messageName)
        let view = BrowserWebView(frame: pageFrame, configuration: configuration)
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = true
        webView = view
        observations = [
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.commitTitle(view.title) }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Same-document navigations (pushState) never "finish"; commit them here.
                    if !view.isLoading { self.commitURL() }
                    self.signalChange()
                }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.chrome.isLoading = view.isLoading
                    self.signalChange()
                }
            },
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.chrome.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.chrome.canGoForward = view.canGoForward }
            },
        ]
        if !isLive { scheduleRelease() }
        return view
    }

    /// Shows the web view in the tile, creating it on first use.
    private func attach() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        ensureWebView()
        placePage()
        setPageActivity(true)
        scheduleSnapshotRefresh()
    }

    /// Where the web view belongs: in the tile while it's live and its window is on screen; in
    /// the stage while an agent drives it and the tile can't show it; otherwise in the live tile
    /// (a hidden page until its window returns) or detached until released.
    private func placePage() {
        guard let webView else { return }
        let shown = isLive && window?.isVisible == true
        if drivenTimer != nil, !shown {
            releaseTimer?.invalidate()
            releaseTimer = nil
            if !WebStage.isParked(webView) { WebStage.park(webView, frame: pageFrame) }
        } else if isLive {
            guard webView.superview !== self else { return }
            webView.frame = pageFrame
            addSubview(webView, positioned: .below, relativeTo: cover)
        } else if webView.superview != nil {
            webView.removeFromSuperview()
            scheduleRelease()
        }
    }

    @objc private func windowVisibilityChanged() {
        placePage()
    }

    /// Page-activity reporting (DOM observer, timers, messages) runs only while on screen.
    private func setPageActivity(_ on: Bool) {
        guard let webView else { return }
        Task { _ = try? await webView.callAsyncJavaScript(BrowserScripts.ensure + "return window.__canvasCmux.setActivity(on)", arguments: ["on": on], in: nil, contentWorld: BrowserScripts.world) }
    }

    /// Drops the web view (its page, history, and web content process share) but keeps the image.
    private func release() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        drivenTimer?.invalidate()
        drivenTimer = nil
        guard let webView else { return }
        observations = []
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        // Closed in the same breath as the stop, a page WebKit treated as visible (the stage) with
        // a navigation in flight leaves a dangling display-link client in WebKit (macOS 26), which
        // crashes the app while its window is minimized; letting the stop settle first doesn't.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay) { _ = webView }
        self.webView = nil
        pendingNavigations = []
        uncommittedNavigations = []
        hover = nil
        signalChange()
    }

    func scheduleRelease() {
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: Self.releaseDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isLive, self.drivenTimer == nil else { return }
                self.release()
            }
        }
    }

    // MARK: Agent-driven pages

    /// Keeps the page visible to WebKit while an agent drives it, so requestAnimationFrame, timers
    /// and IntersectionObserver run as they would for a user: window occlusion detection is off
    /// (another Space or a covered window hides the page too), and while the tile can't show the
    /// page (offscreen, its window minimized or in a background tab, the app hidden) the web view
    /// waits in `WebStage`. `drivenIdle` after the last command the normal detach/release policy
    /// resumes. A page this made visible gets up to `revealWait` to present a frame first, so
    /// the command that follows already sees `visibilityState` "visible".
    func markDriven() async {
        let webView = ensureWebView()
        let wasVisible = webView.superview === self && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        let starting = drivenTimer == nil
        drivenTimer?.invalidate()
        drivenTimer = Timer.scheduledTimer(withTimeInterval: Self.drivenIdle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endDriven() }
        }
        placePage()
        guard starting else { return }
        WebStage.setOcclusionDetection(false, on: webView)
        if window?.occlusionState.contains(.visible) == false { refreshOcclusion(webView) }
        if !wasVisible { await presented(webView, within: Self.revealWait) }
    }

    /// Until the page's next frame is on screen, or `limit` passes.
    private func presented(_ webView: WKWebView, within limit: TimeInterval) async {
        @MainActor final class Once { var done = false }
        let once = Once()
        await withCheckedContinuation { continuation in
            let finish: @MainActor () -> Void = {
                guard !once.done else { return }
                once.done = true
                continuation.resume()
            }
            WebStage.afterNextPresentationUpdate(webView, finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { MainActor.assumeIsolated { finish() } }
        }
    }

    private func endDriven() {
        drivenTimer = nil
        guard let webView else { return }
        WebStage.setOcclusionDetection(true, on: webView)
        if webView.superview === self {
            refreshOcclusion(webView)
        } else {
            placePage()
        }
    }

    /// WebKit re-reads occlusion only on the next window change; re-parenting in the tile forces it.
    private func refreshOcclusion(_ webView: WKWebView) {
        guard webView.superview === self else { return }
        webView.removeFromSuperview()
        addSubview(webView, positioned: .below, relativeTo: cover)
    }

    func load(_ address: String) {
        let webView = webView ?? makeWebView()
        guard let url = BrowserURL.normalize(address) else { return }
        let navigation = url.isFileURL
            ? webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            : webView.load(URLRequest(url: url))
        track(navigation)
    }

    func track(_ navigation: WKNavigation?) {
        guard let navigation else { return }
        pendingNavigations.append(navigation)
        uncommittedNavigations.append(navigation)
    }

    private func submitAddress(_ text: String) {
        guard let url = BrowserURL.normalize(text) else { return NSSound.beep() }
        load(url.absoluteString)
        window?.makeFirstResponder(webView)
    }

    private func commitURL() {
        guard let url = webView?.url?.absoluteString else { return }
        if !chrome.isEditing { chrome.setAddress(url) }
        guard url != object.props["url"]?.string else { return }
        _ = try? board.update(objectID, props: .object(["url": .string(url)]))
    }

    /// The page named itself: the app's write-back, not anyone's edit.
    private func commitTitle(_ title: String?) {
        guard let title, !title.isEmpty, title != object.props["title"]?.string else { return }
        _ = try? board.update(objectID, props: .object(["title": .string(title)]), actor: .system)
    }

    /// A new tile beside this one (⌘-click, `target=_blank`, `window.open`).
    private func openTile(_ url: URL) {
        let size = Board.defaultSize(.browser)
        board.create(type: .browser, props: .object(["url": .string(url.absoluteString)]), frame: board.place(width: size.w, height: size.h, near: objectID))
    }

    // MARK: Change signals (automation waits, snapshot freshness)

    /// Resumes every parked wait; each re-checks its own condition.
    func signalChange() {
        let waiters = changeWaiters.values
        changeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Parks until the page changes or `deadline` passes.
    func nextChange(before deadline: Date) async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            changeWaiters[id] = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) { [weak self] in
                MainActor.assumeIsolated { self?.changeWaiters.removeValue(forKey: id)?.resume() }
            }
        }
    }

    fileprivate func pageMessage(_ kind: String) {
        signalChange()
        // Each new document starts with activity reporting off.
        if kind == "ready", webView?.superview === self { setPageActivity(true) }
        if kind != "ready" { scheduleSnapshotRefresh() }
    }

    /// Keeps `cachedImage` close to what's on screen, at most once per `refreshInterval`.
    func scheduleSnapshotRefresh() {
        guard !refreshScheduled, isLive else { return }
        refreshScheduled = true
        let delay = max(0.25, Self.refreshInterval - Date().timeIntervalSince(lastRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.refreshSnapshot() }
        }
    }

    private func refreshSnapshot() {
        refreshScheduled = false
        guard isLive, let webView, webView.superview === self, webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        lastRefresh = Date()
        let size = webView.bounds.size
        let scale = window?.backingScaleFactor ?? 2
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(min(size.width, (Self.snapshotPixelBudget * size.width / size.height).squareRoot() / scale)))
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, let image else { return }
                self.cachedImage = image
            }
        }
    }

    // MARK: Mentions

    /// A point in this view → CSS pixels in the page's viewport; nil over the chrome.
    private func pagePoint(_ point: NSPoint) -> CGPoint? {
        guard let webView, webView.superview === self else { return nil }
        var local = webView.convert(point, from: self)
        guard webView.bounds.contains(local) else { return nil }
        if !webView.isFlipped { local.y = webView.bounds.height - local.y }
        let zoom = webView.pageZoom * webView.magnification
        return CGPoint(x: local.x / zoom, y: local.y / zoom)
    }

    private func viewRect(_ pageRect: CGRect) -> NSRect? {
        guard let webView, webView.superview === self else { return nil }
        let zoom = webView.pageZoom * webView.magnification
        var rect = NSRect(x: pageRect.minX * zoom, y: pageRect.minY * zoom, width: pageRect.width * zoom, height: pageRect.height * zoom)
        if !webView.isFlipped { rect.origin.y = webView.bounds.height - rect.maxY }
        return convert(rect.intersection(webView.bounds), from: webView)
    }

    private func mention(_ element: WebMentions.Element) -> MentionTarget {
        let url = webView?.url?.absoluteString ?? object.props["url"]?.string ?? ""
        return .dom(object: objectID, url: url, selector: element.selector, text: element.text.isEmpty ? nil : element.text)
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard let page = pagePoint(point) else { return nil }
        if hover?.point != page { requestHover(at: page) }
        guard let hover, hover.element.rect.contains(page) else { return nil }
        return mention(hover.element)
    }

    /// One element lookup in flight at a time; while it runs only the latest point is kept.
    private func requestHover(at point: CGPoint) {
        hoverWanted = point
        guard !hoverInFlight else { return }
        hoverInFlight = true
        Task { [weak self] in
            while let self, let point = self.hoverWanted, let webView = self.webView {
                self.hoverWanted = nil
                let element = await WebMentions.element(at: point, in: webView)
                let changed = element != self.hover?.element
                self.hover = element.map { (point, $0) }
                if changed { NotificationCenter.default.post(name: .tileMentionHoverChanged, object: self) }
            }
            self?.hoverInFlight = false
        }
    }

    func resolveMention(at point: NSPoint) async -> MentionTarget? {
        guard let page = pagePoint(point), let webView,
              let element = await WebMentions.element(at: page, in: webView) else { return nil }
        return mention(element)
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .dom(_, _, let selector, _) = target, let hover, hover.element.selector == selector else { return nil }
        return viewRect(hover.element.rect)
    }

    // MARK: TileContent

    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        if live {
            attach()
        } else {
            readyWaiters.removeAll()
            setPageActivity(false)
            placePage()
        }
    }

    func whenLiveReady(_ ready: @escaping @MainActor () -> Void) {
        readyWaiters.append(ready)
        checkReady()
    }

    /// Ready once the attached page has loaded and that frame is on screen.
    private func checkReady() {
        guard !readyWaiters.isEmpty, isLive, let webView, webView.superview === self, !webView.isLoading else { return }
        WebStage.afterNextPresentationUpdate(webView) { [weak self] in
            guard let self else { return }
            let waiters = self.readyWaiters
            self.readyWaiters.removeAll()
            for ready in waiters { ready() }
        }
    }

    /// The address bar and the page. Rendering counts as driving the page (`markDriven`): one
    /// that isn't loaded, or that its tile can't show now (offscreen, its window minimized or in
    /// a background tab), loads in the stage and is waited for until the render's deadline.
    func render(_ request: TileRenderRequest) async -> TileRender {
        await markDriven()
        if let webView { await settle(webView) }
        return await capture(request)
    }

    /// The zoomed-out card shows the page as it is; only an agent's render loads one.
    func cardSnapshot(_ deliver: @escaping @MainActor (NSImage?) -> Void) {
        let request = TileRenderRequest(size: bounds.size, scale: TileFrameView.cardPixelsPerPoint, full: false,
                                        appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance)
        Task { @MainActor in
            await MainTurns.next()
            let render = await self.capture(request)
            deliver(render.state == .rendered ? render.image : nil)
        }
    }

    /// Until the page has loaded and that frame is presented, or the render is cancelled.
    private func settle(_ webView: WKWebView) async {
        while self.webView === webView, webView.isLoading || !pendingNavigations.isEmpty {
            guard !Task.isCancelled else { return }
            await nextChange(before: Date().addingTimeInterval(0.25))
        }
        guard !Task.isCancelled, self.webView === webView else { return }
        await presented(webView, within: 1)
    }

    /// The address bar and the page as loaded now; a page not loaded yet shows its last capture.
    private func capture(_ request: TileRenderRequest) async -> TileRender {
        let bar = request.image(of: chrome)
        var page: NSImage?
        var reason: String?
        if let webView, webView.window != nil, !webView.isLoading, webView.bounds.width > 0, webView.bounds.height > 0 {
            page = try? await webView.takeSnapshot(configuration: WKSnapshotConfiguration())
            if page == nil { reason = "the page did not produce a snapshot" }
        } else {
            reason = webView?.isLoading == true ? "the page is still loading" : "the page isn't loaded"
            if cachedImage != nil { reason! += "; showing its last capture" }
        }
        let shown = page ?? cachedImage
        let image = request.image { bounds in
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            bar?.drawUpright(in: NSRect(x: 0, y: 0, width: bounds.width, height: Self.chromeHeight))
            shown?.drawUpright(in: NSRect(x: 0, y: Self.chromeHeight, width: bounds.width, height: max(0, bounds.height - Self.chromeHeight)))
        }
        return TileRender(image: image, contentSize: request.size, state: page == nil ? .placeholder : .rendered, reason: page == nil ? reason : nil)
    }

    func showSnapshot(_ show: Bool) {
        let covering = show && webView?.superview === self && cachedImage != nil
        cover.image = covering ? cachedImage : nil
        cover.isHidden = !covering
    }

    var takesKeyboardFocus: Bool { true }

    /// Someone else changed `props.url` (an agent's object.update): go there.
    func update(_ object: CanvasObject) {
        let previous = self.object.props["url"]?.string
        self.object = object
        guard let url = object.props["url"]?.string, url != previous else { return }
        // A released page reloads from props.url when it comes back.
        guard let webView else { return chrome.setAddress(url) }
        if url != webView.url?.absoluteString { load(url) }
    }

    /// File > New Browser Tile: asks for an address and hands it to `open` (which places the
    /// tile in view). A sheet, not an app-modal alert, so the sockets keep answering agents
    /// while the user types.
    static func promptForNew(in window: NSWindow, open: @escaping @MainActor (URL) -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Browser Tile"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "localhost:3000 or https://…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let url = text.isEmpty ? URL(string: "about:blank") : BrowserURL.normalize(text) else { return NSSound.beep() }
            open(url)
        }
    }
}

extension BrowserTile: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command), let url = navigationAction.request.url {
            openTile(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if !uncommittedNavigations.contains(where: { $0 === navigation }) { uncommittedNavigations.append(navigation) }
        signalChange()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        uncommittedNavigations.removeAll { $0 === navigation }
        signalChange()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished(navigation)
        commitURL()
        scheduleSnapshotRefresh()
        checkReady()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finished(navigation)
        checkReady()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finished(navigation)
        checkReady()
        if !chrome.isEditing, let url = webView.url?.absoluteString { chrome.setAddress(url) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pendingNavigations = []
        uncommittedNavigations = []
        track(webView.reload())
        signalChange()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openTile(url) }
        return nil
    }

    private func finished(_ navigation: WKNavigation?) {
        pendingNavigations.removeAll { $0 === navigation }
        uncommittedNavigations.removeAll { $0 === navigation }
        signalChange()
    }
}

/// The first click into a page acts (follows the link, presses the button) even while the
/// window isn't key, as the canvas's own gestures do; WebKit alone only activates the window.
final class BrowserWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The script message handler for page activity. WebKit retains handlers strongly, so this
/// holds the tile weakly to keep the web view from owning its tile.
@MainActor
private final class PageMessages: NSObject, WKScriptMessageHandler {
    weak var tile: BrowserTile?

    init(tile: BrowserTile) {
        self.tile = tile
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let kind = message.body as? String else { return }
        tile?.pageMessage(kind)
    }
}

/// Back, forward, reload, and the address field.
@MainActor
private final class BrowserChrome: NSView, NSTextFieldDelegate {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onSubmit: ((String) -> Void)?
    private let back = BrowserChrome.button("chevron.left", "Back")
    private let forward = BrowserChrome.button("chevron.right", "Forward")
    private let reload = BrowserChrome.button("arrow.clockwise", "Reload")
    private let address = NSTextField()
    private(set) var isEditing = false

    var canGoBack = false { didSet { back.isEnabled = canGoBack } }
    var canGoForward = false { didSet { forward.isEnabled = canGoForward } }
    var isLoading = false {
        didSet { reload.image = NSImage(systemSymbolName: isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: "Reload") }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        back.target = self
        back.action = #selector(backClicked)
        forward.target = self
        forward.action = #selector(forwardClicked)
        reload.target = self
        reload.action = #selector(reloadClicked)
        back.isEnabled = false
        forward.isEnabled = false
        address.bezelStyle = .roundedBezel
        address.font = .systemFont(ofSize: 12)
        address.lineBreakMode = .byTruncatingTail
        address.cell?.isScrollable = true
        address.cell?.wraps = false
        address.placeholderString = "Address"
        address.delegate = self
        address.target = self
        address.action = #selector(addressSubmitted)
        [back, forward, reload, address].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let side: CGFloat = 24
        let y = (bounds.height - side) / 2
        back.frame = NSRect(x: 6, y: y, width: side, height: side)
        forward.frame = NSRect(x: 32, y: y, width: side, height: side)
        reload.frame = NSRect(x: 58, y: y, width: side, height: side)
        address.frame = NSRect(x: 88, y: (bounds.height - 22) / 2, width: max(0, bounds.width - 96), height: 22)
    }

    func setAddress(_ text: String) {
        address.stringValue = text == "about:blank" ? "" : text
    }

    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.toolTip = label
        return button
    }

    @objc private func backClicked() { onBack?() }
    @objc private func forwardClicked() { onForward?() }
    @objc private func reloadClicked() { onReload?() }

    @objc private func addressSubmitted() {
        isEditing = false
        onSubmit?(address.stringValue)
    }

    func controlTextDidBeginEditing(_ obj: Notification) { isEditing = true }
    func controlTextDidEndEditing(_ obj: Notification) { isEditing = false }
}
