import AppKit
import WebKit

/// Element-level mentions for web content (browser and HTML tiles): which DOM element is under a
/// point, a stable CSS selector for it, and where a selector is now. The script runs in its own
/// content world so pages can neither see nor tamper with it.
@MainActor
enum WebMentions {
    static let world = WKContentWorld.world(name: "canvas-mentions")

    struct Element: Equatable, Sendable {
        var selector: String
        var text: String
        /// In the web view's coordinates (CSS pixels at page zoom 1, top-left origin).
        var rect: CGRect
    }

    /// Installs the helper into every frame load of a configuration.
    static func install(on configuration: WKWebViewConfiguration) {
        let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
        configuration.userContentController.addUserScript(script)
    }

    /// The element at `point` (web view coordinates, top-left origin).
    static func element(at point: CGPoint, in webView: WKWebView) async -> Element? {
        let result = try? await webView.callAsyncJavaScript("return window.__canvasMentions?.at(x, y) ?? null", arguments: ["x": point.x, "y": point.y], contentWorld: world)
        return decode(result)
    }

    /// Where the element matching `selector` is now, or nil if it no longer exists.
    static func element(matching selector: String, in webView: WKWebView) async -> Element? {
        let result = try? await webView.callAsyncJavaScript("return window.__canvasMentions?.find(selector) ?? null", arguments: ["selector": selector], contentWorld: world)
        return decode(result)
    }

    private static func decode(_ value: Any?) -> Element? {
        guard let object = value as? [String: Any], let selector = object["selector"] as? String,
              let x = object["x"] as? Double, let y = object["y"] as? Double,
              let w = object["w"] as? Double, let h = object["h"] as? Double else { return nil }
        return Element(selector: selector, text: object["text"] as? String ?? "", rect: CGRect(x: x, y: y, width: w, height: h))
    }

    /// Selector preference: unique id, test ids / aria labels, then a tag:nth-of-type path up to
    /// the nearest ancestor with a unique id.
    static let source = #"""
    (() => {
      const esc = (s) => CSS.escape(s);
      const unique = (sel) => { try { return document.querySelectorAll(sel).length === 1; } catch { return false; } };
      function selectorFor(el) {
        if (!(el instanceof Element)) return null;
        if (el.id && unique('#' + esc(el.id))) return '#' + esc(el.id);
        for (const attr of ['data-testid', 'data-test', 'aria-label', 'name']) {
          const v = el.getAttribute(attr);
          if (v) { const sel = `${el.tagName.toLowerCase()}[${attr}="${v.replace(/"/g, '\\"')}"]`; if (unique(sel)) return sel; }
        }
        const parts = [];
        let node = el;
        while (node && node.nodeType === 1 && node !== document.documentElement) {
          if (node !== el && node.id && unique('#' + esc(node.id))) { parts.unshift('#' + esc(node.id)); break; }
          const tag = node.tagName.toLowerCase();
          const same = node.parentElement ? [...node.parentElement.children].filter((c) => c.tagName === node.tagName) : [];
          parts.unshift(same.length > 1 ? `${tag}:nth-of-type(${same.indexOf(node) + 1})` : tag);
          node = node.parentElement;
        }
        return parts.join(' > ');
      }
      function describe(el) {
        const r = el.getBoundingClientRect();
        const text = (el.innerText || el.getAttribute('aria-label') || el.getAttribute('alt') || el.value || '').trim().replace(/\s+/g, ' ').slice(0, 120);
        return { selector: selectorFor(el), text, x: r.left, y: r.top, w: r.width, h: r.height };
      }
      window.__canvasMentions = {
        at(x, y) { const el = document.elementFromPoint(x, y); return el ? describe(el) : null; },
        find(sel) { try { const el = document.querySelector(sel); return el ? describe(el) : null; } catch { return null; } },
      };
    })();
    """#
}
