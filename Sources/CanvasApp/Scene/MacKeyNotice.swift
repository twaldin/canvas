import AppKit
import CanvasCore

/// A PC habit on the canvas: a ⌃-chord that is a ⌘ shortcut on a Mac (Ctrl+T, Ctrl+W, Ctrl+Z,
/// Ctrl+=) did nothing and said nothing (linux study F1). With the canvas holding the keyboard,
/// such a chord shows a notice naming the Mac key instead, once per chord per session. Never in a
/// terminal, a page or a text field, where ⌃ belongs to the program: they hold the keyboard, so
/// the key never reaches the canvas.
extension CanvasView {
    @MainActor private static var namedMacKeys: Set<String> = []

    /// True when `event` (a key the canvas itself got, nothing else having taken it) is a
    /// ⌃-chord whose ⌘ twin is an easl shortcut and the notice named it, now or earlier this
    /// session.
    func noticeMacKey(for event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.control), !flags.contains(.command), let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
              let twin = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.subtracting(.control).union(.command), timestamp: event.timestamp,
                                          windowNumber: event.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: event.keyCode),
              let (keys, name) = Self.macShortcut(twin) else { return false }
        guard !Self.namedMacKeys.contains(keys) else { return true }
        Self.namedMacKeys.insert(keys)
        showNotice("On a Mac this is \(keys)\(name.map { " (\($0))" } ?? "") · ⌘ is the Windows key on a PC keyboard")
        return true
    }

    /// The shortcut `event` (a ⌘-chord) is, as the menu shows it, and the command's name when a
    /// menu item has it; nil when it is no easl shortcut.
    private static func macShortcut(_ event: NSEvent) -> (keys: String, name: String?)? {
        if let item = CanvasWindowController.menuItem(for: event, in: NSApp.mainMenu) {
            let key = item.keyEquivalent
            return (glyphs(item.keyEquivalentModifierMask, key: key, named: GhosttyConfig.KeyChord(menuKey: key, modifiers: []).key), item.title)
        }
        guard CanvasWindowController.navigationAction(for: event) != nil || CanvasWindowController.tileHeading(for: event) != nil else { return nil }
        return (glyphs(event.modifierFlags, key: event.charactersIgnoringModifiers ?? "", named: CanvasWindowController.keyChord(for: event)?.key), nil)
    }

    /// Named keys' symbols, by their names in `GhosttyConfig.KeyChord`.
    private static let symbols = ["backspace": "⌫", "enter": "↩", "tab": "⇥", "escape": "⎋", "space": "Space",
                                  "arrow_up": "↑", "arrow_down": "↓", "arrow_left": "←", "arrow_right": "→"]

    /// "⌥⇧⌘T": modifiers in the menu's order, then the key (a letter upper case, a named key,
    /// `name` in `KeyChord`'s terms, as its symbol).
    private static func glyphs(_ flags: NSEvent.ModifierFlags, key: String, named name: String?) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) || key != key.lowercased() { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + (name.flatMap { symbols[$0] } ?? key.uppercased())
    }
}
