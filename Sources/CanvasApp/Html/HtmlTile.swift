import AppKit
import CanvasCore
import WebKit

/// Agent- or user-authored HTML in a sandboxed web view (docs/design.md, HTML): a throwaway data
/// store, http(s)/ws blocked except `props.allowNetwork` hosts, and no native bridge beyond the
/// validated `canvas` channel. The web view exists only while the tile is live; offscreen it is
/// released and the tile shows its last snapshot.
@MainActor
final class HtmlTile: NSView, TileContent {
    private(set) var object: CanvasObject
    private let board: Board
    private(set) var webView: WKWebView?
    private var live = true
    private var building = false
    private var loadFailure: NSTextField?
    /// Last rendered image: zoomed-out cards, `object.get --as image`, and `view.snapshot` covers.
    private var lastSnapshot: NSImage?
    private var snapshotCover: NSImageView?
    private var snapshotTask: Task<Void, Never>?
    /// Page scroll reported by the kit, restored after re-renders and re-attachment.
    private var scrollY: Double = 0
    private var hovered: WebMentions.Element?
    private var hoverInFlight = false
    private var queuedHover: NSPoint?
    /// Bounds the native work a page can have outstanding; cancelled when the web view goes away.
    private let work = HtmlWorkQueue()

    init(object: CanvasObject, board: Board) {
        self.object = object
        self.board = board
        super.init(frame: NSRect(x: 0, y: 0, width: object.frame.w, height: object.frame.h))
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    var objectID: ObjectID { object.id }
    var html: String { object.props["html"]?.string ?? "" }
    private var allowNetwork: [String] { object.props["allowNetwork"]?.array?.compactMap(\.string) ?? [] }
    private var pageURL: URL { HtmlKit.pageURL(tile: object.id) }

    // MARK: Web view lifecycle

    /// The rule list compiles asynchronously; the page never loads without it (fail closed), and
    /// never with a list compiled for an allowlist that has since changed.
    private func build() {
        guard live, webView == nil, !building else { return }
        building = true
        let hosts = allowNetwork
        Task { @MainActor [weak self] in
            let rules: WKContentRuleList?
            var failure: Error?
            do {
                rules = try await HtmlRuleLists.list(allowing: hosts)
            } catch {
                rules = nil
                failure = error
            }
            guard let self else { return }
            self.building = false
            guard hosts == self.allowNetwork else { return self.build() }
            guard let rules else { return self.showFailure("Network rules failed to compile: \(failure.map(String.init(describing:)) ?? "")") }
            guard self.live, self.webView == nil else { return }
            self.attach(rules: rules)
        }
    }

    private func attach(rules: WKContentRuleList) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        configuration.setURLSchemeHandler(HtmlSchemeHandler(tile: self), forURLScheme: HtmlKit.scheme)
        configuration.userContentController.addScriptMessageHandler(HtmlChannelHandler(tile: self), contentWorld: .page, name: "canvas")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        WebMentions.install(on: configuration)

        let web = HtmlWebView(frame: bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.uiDelegate = self
        web.underPageBackgroundColor = .textBackgroundColor
        addSubview(web, positioned: .below, relativeTo: nil)
        webView = web
        loadFailure?.removeFromSuperview()
        loadFailure = nil
        web.load(URLRequest(url: pageURL))
    }

    private func detach() {
        snapshotTask?.cancel()
        snapshotTask = nil
        work.cancelAll()
        guard let web = webView else { return }
        web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
        webView = nil
        hovered = nil
    }

    private func showFailure(_ message: String) {
        loadFailure?.removeFromSuperview()
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .systemRed
        label.frame = bounds.insetBy(dx: 12, dy: 12)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
        loadFailure = label
    }

    // MARK: Channel

    func handle(_ message: HtmlMessage) async throws -> JSONValue {
        if case .rendered(let y) = message {
            if let y { scrollY = y }
            scheduleSnapshot()
        }
        return try await work.perform { [object, board] in try await HtmlChannel.handle(message, tile: object.id, board: board) }
    }

    // MARK: Snapshots

    /// WebKit draws outside AppKit, so `cacheDisplay` can't capture it; keep an image of the
    /// settled page instead. Width is capped so large tiles don't hold huge bitmaps.
    private func scheduleSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let web = self.webView, !web.bounds.isEmpty else { return }
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: min(web.bounds.width, 1200))
            if let image = try? await web.takeSnapshot(configuration: configuration), !Task.isCancelled {
                self.lastSnapshot = image
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if webView != nil { scheduleSnapshot() }
    }

    // MARK: TileContent

    func setLive(_ live: Bool) {
        guard live != self.live else { return }
        self.live = live
        if live { build() } else { detach() }
    }

    func snapshot() -> NSImage? { lastSnapshot }

    func showSnapshot(_ show: Bool) {
        snapshotCover?.removeFromSuperview()
        snapshotCover = nil
        guard show, webView != nil, let lastSnapshot else { return }
        let cover = NSImageView(frame: bounds)
        cover.image = lastSnapshot
        cover.imageScaling = .scaleAxesIndependently
        addSubview(cover)
        snapshotCover = cover
    }

    func update(_ object: CanvasObject) {
        let previous = self.object
        self.object = object
        guard let web = webView else { return }
        if (object.props["allowNetwork"] ?? .array([])) != (previous.props["allowNetwork"] ?? .array([])) {
            detach()
            build()
        } else if object.props["html"] != previous.props["html"] {
            work.cancelAll()
            web.load(URLRequest(url: pageURL))
        } else if object.props["state"] != previous.props["state"] {
            let state = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(object.props["state"] ?? .object([:])))) ?? [String: Any]()
            Task { _ = try? await web.callAsyncJavaScript("window.canvasKit?.receiveState(state)", arguments: ["state": state], contentWorld: .page) }
        }
    }

    /// Element-level: the DOM element under the pointer, from the tile's canvas-kit page.
    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard webView != nil else { return nil }
        requestHover(at: point)
        return hovered.map(domTarget)
    }

    func resolveMention(at point: NSPoint) async -> MentionTarget? {
        guard let web = webView, let element = await WebMentions.element(at: point, in: web) else { return nil }
        hovered = element
        return domTarget(element)
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .dom(_, _, let selector, _) = target, let hovered, hovered.selector == selector else { return bounds }
        return hovered.rect.intersection(bounds)
    }

    var takesKeyboardFocus: Bool { false }

    private func domTarget(_ element: WebMentions.Element) -> MentionTarget {
        .dom(object: object.id, url: pageURL.absoluteString, selector: element.selector, text: element.text.isEmpty ? nil : element.text)
    }

    /// One element lookup in flight at a time; the latest pointer position wins.
    private func requestHover(at point: NSPoint) {
        guard !hoverInFlight else {
            queuedHover = point
            return
        }
        guard let web = webView else { return }
        hoverInFlight = true
        Task { @MainActor [weak self] in
            let element = await WebMentions.element(at: point, in: web)
            guard let self else { return }
            self.hoverInFlight = false
            if element != self.hovered {
                self.hovered = element
                NotificationCenter.default.post(name: .tileMentionHoverChanged, object: self)
            }
            if let next = self.queuedHover {
                self.queuedHover = nil
                self.requestHover(at: next)
            }
        }
    }
}

extension HtmlTile: WKNavigationDelegate, WKUIDelegate {
    /// The page may load only its own document and kit; links never navigate the tile away.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let isMain = action.targetFrame?.isMainFrame ?? true
        if isMain { return url.scheme == HtmlKit.scheme && url.host == HtmlKit.host && url.path == pageURL.path ? .allow : .cancel }
        return ["about", "data", "blob", HtmlKit.scheme].contains(url.scheme ?? "") ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard scrollY > 0 else { return }
        let y = scrollY
        Task { _ = try? await webView.callAsyncJavaScript("window.canvasKit?.restoreScroll(y)", arguments: ["y": y], contentWorld: .page) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: pageURL))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}
