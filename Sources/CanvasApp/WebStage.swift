import AppKit
import WebKit

/// Where web views wait while nobody sees them but WebKit must still treat them as visible
/// (a detached or hidden-ancestor view is a hidden page: no layout, no requestAnimationFrame):
/// a zero-size clipped view inside the window's content, plus window occlusion detection off
/// (another Space or a covered window hides the page too).
@MainActor
enum WebStage {
    private static let stageID = NSUserInterfaceItemIdentifier("canvas.webStage")

    /// Parks `view` in the window's stage at `frame`; false when there's no window.
    @discardableResult
    static func park(_ view: NSView, frame: NSRect, in window: NSWindow?) -> Bool {
        guard let content = window?.contentView else { return false }
        let stage = content.subviews.first { $0.identifier == stageID } ?? {
            let stage = NSView(frame: .zero)
            stage.identifier = stageID
            stage.clipsToBounds = true
            content.addSubview(stage)
            return stage
        }()
        view.frame = frame
        if view.superview !== stage { stage.addSubview(view) }
        return true
    }

    static func isParked(_ view: NSView) -> Bool {
        view.superview?.identifier == stageID
    }

    /// WebKit SPI `-[WKWebView _setWindowOcclusionDetectionEnabled:]` (macOS 10.13+); skipped if absent.
    static func setOcclusionDetection(_ enabled: Bool, on webView: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, enabled)
    }
}
