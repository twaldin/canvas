import AppKit
import CanvasCore

/// Window-space bar showing staged mentions as chips and the terminal they will drain into.
@MainActor
final class TrayBar: NSVisualEffectView {
    private let stack = NSStackView()
    private let target = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Hyper-click (⌃⌥⇧⌘-click) anything to point your agent at it")
    var onUnstage: ((MentionID) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        target.textColor = .secondaryLabelColor
        target.font = .systemFont(ofSize: 12, weight: .medium)
        target.alignment = .right
        target.toolTip = CanvasBasics.trayTarget
        for view in [stack, target] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: target.leadingAnchor, constant: -12),
            target.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            target.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        show([], targetTitle: nil, targetDrains: false, hasTerminal: false)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// `targetTitle` is the prompt target's; without one, the hint says how to get one.
    /// `targetDrains`: the target runs an agent integration that takes the tray with its next
    /// prompt; any other target needs Hyper-V to paste the mentions.
    func show(_ mentions: [Mention], targetTitle: String?, targetDrains: Bool, hasTerminal: Bool) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        if mentions.isEmpty { stack.addArrangedSubview(hint) }
        for mention in mentions { stack.addArrangedSubview(chip(for: mention)) }
        target.stringValue = targetTitle.map { mentions.isEmpty || targetDrains ? "→ \($0)" : "→ \($0) · ⌃⌥⇧⌘V pastes" } ?? (hasTerminal ? "→ click a terminal to target it" : "→ no terminal yet (⌘T)")
    }

    private func chip(for mention: Mention) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 7
        box.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.22).cgColor
        let label = NSTextField(labelWithString: mention.label)
        label.font = .systemFont(ofSize: 12)
        // DOM labels lead with what a person recognizes and end with the CSS path; code
        // locations keep both the file name's start and its line.
        if case .dom = mention.target { label.lineBreakMode = .byTruncatingTail } else { label.lineBreakMode = .byTruncatingMiddle }
        // A file outside the board root has a short label (`PathLabel`); the tooltip has its path.
        if case .code(_, let path, _, _, _, _, _) = mention.target, PathLabel.short(path) != path { label.toolTip = path }
        let remove = NSButton(title: "✕", target: self, action: #selector(removeClicked(_:)))
        remove.isBordered = false
        remove.identifier = NSUserInterfaceItemIdentifier(mention.id)
        // Outside the label, so truncation never hides it.
        let edited = mention.edited ? [NSTextField(labelWithString: "· edited")] : []
        edited.forEach { $0.font = .systemFont(ofSize: 12) }
        let row = NSStackView(views: [label] + edited + [remove])
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            row.topAnchor.constraint(equalTo: box.topAnchor),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        return box
    }

    @objc private func removeClicked(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onUnstage?(id) }
    }
}
