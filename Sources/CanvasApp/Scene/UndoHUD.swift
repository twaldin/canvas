import AppKit

/// A brief, non-modal note above the tray saying what an undo or redo of someone else's change
/// did ("Undid omp: created 9 code tiles, 6 arrows · ⇧⌘Z redoes"). It never takes the keyboard
/// or the mouse and goes after a few seconds.
@MainActor
final class UndoHUD: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var hide: DispatchWorkItem?
    static let shownFor: TimeInterval = 4

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        isHidden = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String) {
        label.stringValue = text
        label.toolTip = text
        setAccessibilityLabel(text)
        hide?.cancel()
        isHidden = false
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.isHidden = true }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shownFor, execute: work)
    }
}
