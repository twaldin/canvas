import AppKit

/// A short message at the bottom center of the view that goes away by itself: a command with
/// nothing to act on says so instead of doing nothing (`CanvasView.showNotice`). It never takes
/// clicks or the keyboard, and VoiceOver announces it.
@MainActor
final class NoticePill: NSVisualEffectView {
    static let duration: TimeInterval = 2.5
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `text` centered `bottom` points above the bottom edge of `container`, for
    /// `duration`; a newer notice replaces it and restarts the clock.
    func show(_ text: String, in container: NSView, bottom: CGFloat) {
        label.stringValue = text
        label.sizeToFit()
        let width = min(label.frame.width + 28, max(120, container.bounds.width - 40))
        let y = container.isFlipped ? container.bounds.height - bottom - 28 : bottom
        frame = NSRect(x: ((container.bounds.width - width) / 2).rounded(), y: y.rounded(), width: width, height: 28)
        autoresizingMask = [.minXMargin, .maxXMargin, container.isFlipped ? .minYMargin : .maxYMargin]
        label.frame = NSRect(x: 14, y: ((28 - label.frame.height) / 2).rounded(), width: width - 28, height: label.frame.height)
        isHidden = false
        alphaValue = 1
        NSAccessibility.post(element: container, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.alphaValue == 0 else { return }
                    self.isHidden = true
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }
}

extension CanvasView {
    /// Says `text` for a moment at the bottom center of the view, above the tray and the
    /// "Nothing here" pill: for a command that found nothing to act on (⌃⌘R with no code tile,
    /// ⌘J with nothing pending), so a key press never does silently nothing.
    func showNotice(_ text: String) {
        let pill = subviews.lazy.compactMap { $0 as? NoticePill }.first ?? {
            let pill = NoticePill(frame: .zero)
            addSubview(pill)
            return pill
        }()
        pill.show(text, in: self, bottom: chromeInsets().bottom + 50)
    }
}
