import AppKit
import CanvasCore

/// A tile's text for VoiceOver: a read-only text area inside the tile's accessibility group
/// (`TileFrameView`), covering `view`, whose text (`AccessibleText`) is built only when
/// assistive technology asks, and kept for a moment, since one read asks for the value, its
/// length and line ranges one after another. A code tile gives its lines, a terminal its screen.
@MainActor
final class AccessibleTextElement: NSAccessibilityElement {
    private weak var view: NSView?
    private let label: () -> String?
    private let read: () -> AccessibleText?
    private var cached: (text: AccessibleText, at: Date)?
    /// How long one read's text is reused.
    private static let reuse: TimeInterval = 0.5

    init(view: NSView, label: @escaping () -> String?, read: @escaping () -> AccessibleText?) {
        self.view = view
        self.label = label
        self.read = read
        super.init()
    }

    private var text: AccessibleText {
        if let cached, Date().timeIntervalSince(cached.at) < Self.reuse { return cached.text }
        let text = read() ?? AccessibleText("")
        cached = (text, Date())
        return text
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { onMain { $0.label() } }
    override func accessibilityParent() -> Any? { onMain { $0.view.flatMap { NSAccessibility.unignoredAncestor(of: $0) } } }
    override func accessibilityFrame() -> NSRect {
        onMain { element in
            guard let view = element.view, view.window != nil else { return .zero }
            return NSAccessibility.screenRect(fromView: view, rect: view.bounds)
        }
    }
    override func isAccessibilityFocused() -> Bool { false }
    override func accessibilityValue() -> Any? { onMain { $0.text.text } }
    override func accessibilityNumberOfCharacters() -> Int { onMain { $0.text.length } }
    override func accessibilityVisibleCharacterRange() -> NSRange { onMain { NSRange(location: 0, length: $0.text.length) } }
    override func accessibilitySelectedTextRange() -> NSRange { NSRange(location: 0, length: 0) }
    override func accessibilitySelectedText() -> String? { "" }
    override func accessibilityString(for range: NSRange) -> String? { onMain { $0.text.string(in: range) } }
    override func accessibilityLine(for index: Int) -> Int { onMain { $0.text.line(at: index) } }
    override func accessibilityRange(forLine line: Int) -> NSRange { onMain { $0.text.range(ofLine: line) } }
    override func accessibilityFrame(for range: NSRange) -> NSRect { accessibilityFrame() }

    /// AppKit declares the accessibility methods nonisolated but calls them on the main thread.
    private nonisolated func onMain<T>(_ body: @MainActor (AccessibleTextElement) -> T) -> T {
        nonisolated(unsafe) let element = self
        nonisolated(unsafe) var result: T?
        MainActor.assumeIsolated { result = body(element) }
        return result!
    }
}
