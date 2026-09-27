import AppKit
import CanvasCore
import WebKit

/// The WebKit side of the cmux subset: runs validated commands against a browser tile's page.
/// Commands work whether or not the tile is on screen; a released page is rebuilt from its URL.
extension BrowserTile {
    /// `driver`: the terminal sending the command (`CmuxRouter.driver`), nil when unknown. A
    /// command that can act on the page (navigate, click, type, run script) takes the credit
    /// for what the page does next, as it starts and again as it ends (`NavigationCredit`).
    func perform(_ command: CmuxBrowserCommand, driver: ObjectID?) async throws -> JSONValue {
        let webView = ensureWebView()
        await markDriven()
        let acts = Self.acts(command)
        if acts { credit.agent(driver) }
        defer {
            if acts { credit.agent(driver) }
            scheduleSnapshotRefresh()
        }
        switch command {
        case .navigate(let url):
            load(url)
            return .object(["url": .string(url)])
        case .back:
            if webView.canGoBack { track(webView.goBack()) }
            return .object(location(webView))
        case .forward:
            if webView.canGoForward { track(webView.goForward()) }
            return .object(location(webView))
        case .reload:
            track(webView.reload())
            return .object(location(webView))
        case .urlGet:
            var result = location(webView)
            result["title"] = .string(webView.title ?? "")
            return .object(result)
        case .eval(let script):
            return .object(["value": try await evaluate(script, in: webView)])
        case .snapshot(let interactive, let maxDepth):
            return try await call("return window.__canvasCmux.snapshot(interactive, maxDepth)",
                                  ["interactive": interactive, "maxDepth": maxDepth.map { $0 as Any } ?? NSNull()], in: webView)
        case .screenshot:
            return try await screenshot(webView)
        case .element(let action, let selector):
            return try await act(action.rawValue, selector, "", in: webView)
        case .type(let selector, let text):
            return try await act("type", selector, text, in: webView)
        case .fill(let selector, let text):
            return try await act("fill", selector, text, in: webView)
        case .press(let key):
            return try await call("return window.__canvasCmux.press(key)", ["key": key], in: webView)
        case .scroll(let dx, let dy):
            return try await call("return window.__canvasCmux.scroll(dx, dy)", ["dx": dx, "dy": dy], in: webView)
        case .wait(let condition, let timeoutMs):
            try await wait(for: condition, deadline: Date().addingTimeInterval(Double(timeoutMs) / 1000))
            return .object(location(ensureWebView()))
        }
    }

    /// Whether a command can change the page's location or open a tile.
    private static func acts(_ command: CmuxBrowserCommand) -> Bool {
        switch command {
        case .navigate, .back, .forward, .reload, .eval, .element, .type, .fill, .press: true
        case .urlGet, .snapshot, .screenshot, .scroll, .wait: false
        }
    }

    private func location(_ webView: WKWebView) -> [String: JSONValue] {
        ["url": .string(webView.url?.absoluteString ?? object.props["url"]?.string ?? "about:blank")]
    }

    private func act(_ action: String, _ selector: String, _ text: String, in webView: WKWebView) async throws -> JSONValue {
        try await call("return window.__canvasCmux.act(action, selector, text)", ["action": action, "selector": selector, "text": text], in: webView)
    }

    // MARK: Waits

    /// Checks the condition, then parks until the page changes; never polls.
    private func wait(for condition: CmuxWaitCondition, deadline: Date) async throws {
        while true {
            guard board.objects[objectID] != nil else { throw CmuxError("not_found", "surface \(objectID) was closed") }
            let webView = ensureWebView()
            if try await satisfied(condition, in: webView, deadline: deadline) { return }
            guard Date() < deadline else { throw CmuxError("timeout", "timed out waiting for \(Self.describe(condition))") }
            await nextChange(before: deadline)
        }
    }

    private func satisfied(_ condition: CmuxWaitCondition, in webView: WKWebView, deadline: Date) async throws -> Bool {
        switch condition {
        case .urlContains(let fragment):
            return webView.url?.absoluteString.contains(fragment) == true
        case .loadState(let state):
            // `interactive` only needs the destination document to have replaced the old one
            // (DOMContentLoaded); `complete` also waits for WebKit to finish every subresource.
            switch state {
            case .interactive: guard uncommittedNavigations.isEmpty else { return false }
            case .complete: guard pendingNavigations.isEmpty, !webView.isLoading else { return false }
            }
            // A document torn down mid-check is simply not ready yet.
            let ready = (try? await call("return document.readyState", [:], in: webView))?.string
            return state == .complete ? ready == "complete" : ready == "interactive" || ready == "complete"
        case .selector(let selector):
            let remaining = max(0, Int(deadline.timeIntervalSinceNow * 1000))
            do {
                return try await call("return await window.__canvasCmux.waitFor(selector, timeout)",
                                      ["selector": selector, "timeout": remaining], in: webView) == .bool(true)
            } catch let error as CmuxError where error.code == "invalid_params" {
                throw error
            } catch {
                // The document went away (navigation); try again in the next one.
                return false
            }
        }
    }

    private static func describe(_ condition: CmuxWaitCondition) -> String {
        switch condition {
        case .loadState(let state): "load state \(state.rawValue)"
        case .urlContains(let fragment): "a URL containing \(fragment)"
        case .selector(let selector): "selector \(selector)"
        }
    }

    // MARK: JavaScript

    /// Runs `body` as an async function in the automation world, installing the helper if the
    /// document predates it. Results must be JSON-shaped.
    private func call(_ body: String, _ arguments: [String: Any], in webView: WKWebView) async throws -> JSONValue {
        do {
            let value = try await webView.callAsyncJavaScript(BrowserScripts.ensure + body, arguments: arguments, in: nil, contentWorld: BrowserScripts.world)
            return Self.json(value)
        } catch {
            throw Self.cmuxError(error)
        }
    }

    /// `browser.eval` in the page's own world: an expression's promise is awaited; statements
    /// run as a program (see `CmuxEval`). Neither is subject to the page's CSP.
    private func evaluate(_ script: String, in webView: WKWebView) async throws -> JSONValue {
        if let body = CmuxEval.awaitingBody(script) {
            do {
                return Self.json(try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page))
            } catch {
                throw Self.cmuxError(error)
            }
        }
        // The completion-handler form: the async overload can't return a program's `undefined`.
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: Self.cmuxError(error))
                } else {
                    continuation.resume(returning: Self.json(value))
                }
            }
        }
    }

    /// Page exceptions named like `not_found: …` (the helper's own failures) keep their code.
    static func cmuxError(_ error: Error) -> CmuxError {
        let nsError = error as NSError
        guard nsError.domain == WKError.errorDomain else { return CmuxError("js_error", nsError.localizedDescription) }
        switch WKError.Code(rawValue: nsError.code) {
        case .javaScriptExceptionOccurred:
            let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? nsError.localizedDescription
            if let match = message.firstMatch(of: /^(not_found|invalid_params): (.*)$/) {
                return CmuxError(String(match.1), String(match.2))
            }
            // Awaited expressions report line 0 (the async wrapper), which says nothing.
            let line = (nsError.userInfo["WKJavaScriptExceptionLineNumber"] as? NSNumber).flatMap { $0.intValue > 0 ? " (line \($0))" : nil } ?? ""
            return CmuxError("js_error", message + line)
        case .javaScriptResultTypeIsUnsupported:
            return CmuxError("js_error", "the script's result can't be serialized: return JSON-like values, not DOM nodes or functions (a promise is awaited only when the script is one expression)")
        default:
            return CmuxError("js_error", nsError.localizedDescription)
        }
    }

    /// Foundation values from WebKit (NSNumber, NSString, NSArray, NSDictionary, NSNull, NSDate).
    static func json(_ value: Any?) -> JSONValue {
        switch value {
        case nil, is NSNull: return .null
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: return .string(string)
        case let date as Date: return .number(date.timeIntervalSince1970 * 1000)
        case let array as [Any]: return .array(array.map { json($0) })
        case let object as [String: Any]: return .object(object.mapValues { json($0) })
        default: return .string(String(describing: value!))
        }
    }

    // MARK: Screenshot

    /// The viewport at one image pixel per CSS pixel, which is what omp compares against
    /// `innerWidth`/`innerHeight`.
    private func screenshot(_ webView: WKWebView) async throws -> JSONValue {
        let size = webView.bounds.size
        guard size.width >= 1, size.height >= 1 else { throw CmuxError("unavailable", "the browser tile has no visible area") }
        let zoom = webView.pageZoom * webView.magnification
        let width = Int((size.width / zoom).rounded()), height = Int((size.height / zoom).rounded())
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image: NSImage
        do {
            image = try await webView.takeSnapshot(configuration: configuration)
        } catch {
            throw CmuxError("unavailable", "screenshot failed: \(error.localizedDescription)")
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CmuxError("unavailable", "screenshot buffer unavailable")
        }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CmuxError("unavailable", "PNG encoding failed") }
        return .object([
            "png_base64": .string(png.base64EncodedString()),
            "width": .number(Double(width)),
            "height": .number(Double(height)),
            "url": .string(webView.url?.absoluteString ?? ""),
        ])
    }
}
