import AppKit

/// Centred on a board with no objects: how to start (a terminal, then your agent), what Hyper
/// does, and where the legend is (Help › Canvas Basics). A quiet panel, transparent to the mouse, so the canvas under it still takes
/// clicks and the right-click menu.
@MainActor
final class EmptyBoardHint: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        let lines: [(String, NSFont, NSColor)] = [
            ("Press ⌘T for a terminal, then run any agent CLI.", .systemFont(ofSize: 15, weight: .medium), .labelColor),
            ("omp, claude, codex, gemini, and opencode report when they need you, follow their reads, and get your mentions; aider says when it waits.", .systemFont(ofSize: 13), .secondaryLabelColor),
            ("Or right-click anywhere → New Terminal Here.", .systemFont(ofSize: 13), .secondaryLabelColor),
            ("Hyper is ⌃⌥⇧⌘: Hyper-click code, notes, shapes, or web pages to point your agent at them.", .systemFont(ofSize: 13), .secondaryLabelColor),
            ("New here? Help › Canvas Basics explains the dots, markers, tray, and keys.", .systemFont(ofSize: 13), .tertiaryLabelColor),
        ]
        for (text, font, color) in lines {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = color
            label.alignment = .center
            stack.addArrangedSubview(label)
        }
        stack.setCustomSpacing(4, after: stack.arrangedSubviews[0])
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
