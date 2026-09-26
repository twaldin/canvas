import AppKit

/// Development input replay (`CANVAS_DEV_INPUT=1`, driven by `scripts/dev-input.swift`).
/// Agents test the UI while the window sits on a Space nobody is viewing, where real HID input
/// can't reach it and posting system events needs a TCC grant. Events go into this app's own
/// queue, so the Hyper monitor, hit testing, and responders run exactly as for real input.
/// See docs/testing.md.
@MainActor
enum DevInput {
    static let notification = Notification.Name("canvas.dev.input")
    /// Where replayed modifier changes happen; real input uses the actual mouse location.
    static var pointer: NSPoint?

    static func install() {
        guard ProcessInfo.processInfo.environment["CANVAS_DEV_INPUT"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            var fields: [String: String] = [:]
            for (key, value) in note.userInfo ?? [:] {
                if let key = key as? String { fields[key] = "\(value)" }
            }
            MainActor.assumeIsolated { replay(fields) }
        }
    }

    static func modifiers(_ names: String?) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in (names ?? "").split(separator: "+") {
            switch name {
            case "hyper": flags.formUnion([.control, .option, .shift, .command])
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        return flags
    }

    static func replay(_ fields: [String: String]) {
        guard fields["pid"] == String(getpid()) else { return }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.windowController is CanvasWindowController }),
              let content = window.contentView else { return }
        let flags = modifiers(fields["mods"])
        func number(_ key: String) -> CGFloat { CGFloat(Double(fields[key] ?? "") ?? 0) }
        /// Window content points with a top-left origin → window coordinates.
        func point(_ x: String, _ y: String) -> NSPoint {
            window.contentView!.convert(NSPoint(x: number(x), y: content.bounds.height - number(y)), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, _ at: NSPoint, clicks: Int = 1) {
            let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
        }
        switch fields["kind"] {
        case "click":
            let at = point("x", "y")
            let clicks = Int(fields["clicks"] ?? "") ?? 1
            for click in 1...max(1, clicks) {
                mouse(.leftMouseDown, at, clicks: click)
                mouse(.leftMouseUp, at, clicks: click)
            }
        case "rightclick":
            let at = point("x", "y")
            mouse(.rightMouseDown, at)
            mouse(.rightMouseUp, at)
        case "drag":
            let start = point("x", "y")
            let end = point("toX", "toY")
            mouse(.leftMouseDown, start)
            for step in 1...8 {
                let t = CGFloat(step) / 8
                mouse(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            mouse(.leftMouseUp, end)
        case "flags":
            // Holding (or releasing) modifiers with the pointer at x,y: drives hover outlines.
            pointer = point("x", "y")
            if let event = NSEvent.keyEvent(with: .flagsChanged, location: point("x", "y"), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0) {
                NSApp.postEvent(event, atStart: false)
            }
        case "text":
            (window.firstResponder as? NSTextInputClient)?.insertText(fields["text"] ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
        case "command":
            window.firstResponder?.doCommand(by: NSSelectorFromString(fields["selector"] ?? ""))
        case "shortcut":
            let key = fields["key"] ?? ""
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else { return }
            if !window.performKeyEquivalent(with: event) { _ = NSApp.mainMenu?.performKeyEquivalent(with: event) }
        case "scroll":
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(number("dy")), wheel2: Int32(number("dx")), wheel3: 0) else { return }
            cg.location = window.convertPoint(toScreen: point("x", "y"))
            cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
        default:
            NSLog("DevInput: unknown kind \(fields["kind"] ?? "nil")")
        }
    }
}
