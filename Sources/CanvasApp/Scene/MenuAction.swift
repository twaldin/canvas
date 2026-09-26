import AppKit

/// A context-menu item that runs a closure; the item keeps its handler alive.
@MainActor
final class MenuAction: NSObject {
    private let handler: () -> Void

    private init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc private func run(_ sender: Any?) { handler() }

    static func item(_ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: enabled ? #selector(run(_:)) : nil, keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}
