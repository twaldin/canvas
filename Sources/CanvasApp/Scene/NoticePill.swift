import AppKit
import CanvasCore

/// A short message at the bottom center of the view that goes away by itself: a command with
/// nothing to act on says so instead of doing nothing (`CanvasView.showNotice`). It never takes
/// clicks or the keyboard, and VoiceOver announces it.
@MainActor
final class NoticePill: NSVisualEffectView {
    /// Long enough to find and read with a screen magnifier panned elsewhere (2.5 s wasn't).
    static let duration: TimeInterval = 4
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
    /// ⌘J with nothing pending), so a key press never does silently nothing, and for what a key
    /// did that nothing else shows (Esc keeping theirs over a conflicting note edit).
    func showNotice(_ text: String) {
        let pill = subviews.lazy.compactMap { $0 as? NoticePill }.first ?? {
            let pill = NoticePill(frame: .zero)
            addSubview(pill)
            return pill
        }()
        pill.show(text, in: self, bottom: chromeInsets().bottom + 50)
    }

    /// Where an object is when it isn't wholly in the view clear of the chrome ("out of view to
    /// the right", "partly below the view"), for a notice about something that landed there without
    /// the view moving; nil when it is in view.
    func outOfView(_ id: ObjectID) -> String? {
        guard let frame = board.objects[id]?.frame else { return nil }
        let view = clearViewport
        if frame.x >= view.x, frame.y >= view.y, frame.x + frame.w <= view.x + view.w, frame.y + frame.h <= view.y + view.h { return nil }
        let partly = frame.x < view.x + view.w && view.x < frame.x + frame.w && frame.y < view.y + view.h && view.y < frame.y + frame.h ? "partly " : ""
        let dx = (frame.x + frame.w / 2 - (view.x + view.w / 2)) / max(1, view.w)
        let dy = (frame.y + frame.h / 2 - (view.y + view.h / 2)) / max(1, view.h)
        if abs(dx) >= abs(dy) { return partly + (dx > 0 ? "out of view to the right" : "out of view to the left") }
        return partly + (dy > 0 ? "below the view" : "above the view")
    }
}
