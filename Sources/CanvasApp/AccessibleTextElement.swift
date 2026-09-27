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
    override func accessibilityLabel() -> String? { label() }
    override func accessibilityParent() -> Any? { view.flatMap { NSAccessibility.unignoredAncestor(of: $0) } }
    override func accessibilityFrame() -> NSRect {
        guard let view, view.window != nil else { return .zero }
        return NSAccessibility.screenRect(fromView: view, rect: view.bounds)
    }
    override func isAccessibilityFocused() -> Bool { false }
    override func accessibilityValue() -> Any? { text.text }
    override func accessibilityNumberOfCharacters() -> Int { text.length }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: text.length) }
    override func accessibilitySelectedTextRange() -> NSRange { NSRange(location: 0, length: 0) }
    override func accessibilitySelectedText() -> String? { "" }
    override func accessibilityString(for range: NSRange) -> String? { text.string(in: range) }
    override func accessibilityLine(for index: Int) -> Int { text.line(at: index) }
    override func accessibilityRange(forLine line: Int) -> NSRange { text.range(ofLine: line) }
    override func accessibilityFrame(for range: NSRange) -> NSRect { accessibilityFrame() }
}
