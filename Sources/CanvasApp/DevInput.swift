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

    private static func button(in view: NSView?, keyEquivalent key: String) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, !key.isEmpty, button.keyEquivalent == key { return button }
        return view.subviews.lazy.compactMap { button(in: $0, keyEquivalent: key) }.first
    }

    static func replay(_ fields: [String: String]) {
        guard fields["pid"] == String(getpid()) else { return }
        // `--repeat N --interval ms`: a burst like a trackpad's event stream. The log line reports
        // the longest gap between consecutive steps (the longest stall a person sees as frozen
        // frames) and the mean lateness against the schedule. Steps come from one strict repeating
        // timer: separate `asyncAfter` calls get leeway proportional to their delay, which showed
        // up as stalls growing through the burst while the main thread sat idle.
        if let count = Int(fields["repeat"] ?? ""), count > 1 {
            var single = fields
            single["repeat"] = nil
            let interval = (Double(fields["interval"] ?? "") ?? 8) / 1000
            @MainActor final class Burst {
                let start = Date()
                var step = 0, last: Date?, gap = 0.0, gapStep = 0, lateness = 0.0
                var timer: DispatchSourceTimer?
            }
            let burst = Burst()
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            burst.timer = timer
            timer.schedule(deadline: .now(), repeating: interval, leeway: .nanoseconds(0))
            timer.setEventHandler {
                MainActor.assumeIsolated {
                    let now = Date(), step = burst.step
                    burst.step += 1
                    burst.lateness += max(0, now.timeIntervalSince(burst.start) - interval * Double(step)) * 1000
                    if let last = burst.last, now.timeIntervalSince(last) * 1000 > burst.gap {
                        burst.gap = now.timeIntervalSince(last) * 1000
                        burst.gapStep = step
                    }
                    burst.last = now
                    // A scroll burst is one trackpad gesture: began, changed…, ended.
                    var event = single
                    event["phase"] = step == 0 ? "began" : step == count - 1 ? "ended" : "changed"
                    replay(event)
                    guard step == count - 1 else { return }
                    burst.timer?.cancel()
                    burst.timer = nil
                    NSLog("DevInput: burst of %d %@ took %.0f ms (scheduled %.0f ms), longest gap %.1f ms before step %d, mean lateness %.1f ms",
                          count, fields["kind"] ?? "", Date().timeIntervalSince(burst.start) * 1000, interval * 1000 * Double(count - 1),
                          burst.gap, burst.gapStep, burst.lateness / Double(count))
                }
            }
            timer.resume()
            return
        }
        // The front board window: with tabs, the selected tab (the others are ordered out).
        guard let window = NSApp.orderedWindows.first(where: { window in
                  window.isVisible && window.windowController is CanvasWindowController
                      && (window.tabGroup.map { $0.selectedWindow === window } ?? true)
              }),
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
        case "move":
            // Tracking-area mouseMoved events come from the window server; a posted mouseMoved
            // never reaches their owners. Deliver it to the areas under the point directly.
            let at = point("x", "y")
            guard let frame = content.superview, let hit = content.hitTest(frame.convert(at, from: nil)),
                  let event = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
            for view in sequence(first: hit, next: \.superview) {
                let local = view.convert(at, from: nil)
                for area in view.trackingAreas where area.options.contains(.mouseMoved) {
                    let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                    // Owners needn't be responders (any object implementing mouseMoved:).
                    let moved = #selector(NSResponder.mouseMoved(with:))
                    if rect.contains(local), let owner = area.owner as? NSObject, owner.responds(to: moved) { owner.perform(moved, with: event) }
                }
            }
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
            // Typing goes to a sheet (e.g. the group-name prompt) when one is open.
            ((window.attachedSheet ?? window).firstResponder as? NSTextInputClient)?.insertText(fields["text"] ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
        case "command":
            (window.attachedSheet ?? window).firstResponder?.doCommand(by: NSSelectorFromString(fields["selector"] ?? ""))
        case "shortcut":
            let key = fields["key"] ?? ""
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else { return }
            // A sheet in a window that isn't key ignores key equivalents (an alert's default button
            // only gets Return once key), so press the matching button, or accept on Return.
            if let sheet = window.attachedSheet {
                if let pressed = button(in: sheet.contentView, keyEquivalent: key) { return pressed.performClick(nil) }
                if key == "\r" || key == "\n" { return window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            }
            if !window.performKeyEquivalent(with: event) { _ = NSApp.mainMenu?.performKeyEquivalent(with: event) }
        case "scroll":
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(number("dy")), wheel2: Int32(number("dx")), wheel3: 0) else { return }
            // CGEvent locations are global with a top-left origin (primary display), not Cocoa's.
            let at = point("x", "y")
            let screen = window.convertPoint(toScreen: at)
            cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            // A phased, continuous event is a trackpad gesture step; a phaseless one is a mouse
            // wheel notch, which AppKit animates as a smooth scroll.
            let phases: [String: Int64] = ["began": 1, "changed": 2, "ended": 4]
            if let phase = fields["phase"].flatMap({ phases[$0] }) {
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            }
            // A window-less event's locationInWindow is its screen location, which only matches the
            // window near the primary display's origin; hand it to the view under the point instead
            // of relying on sendEvent's hit test (windows on other displays got nothing).
            guard let event = NSEvent(cgEvent: cg), let frame = content.superview,
                  let hit = content.hitTest(frame.convert(at, from: nil)) else { return }
            hit.scrollWheel(with: event)
        case "magnify":
            // A trackpad pinch step: NSEvent can't make gesture events, so drive the scroll view the
            // way its own magnify(with:) does (live-magnify notifications around the steps).
            let at = point("x", "y")
            guard let frame = content.superview, var view = content.hitTest(frame.convert(at, from: nil)) else { return }
            while !(view is NSScrollView), let parent = view.superview { view = parent }
            guard let scroll = view as? NSScrollView, scroll.allowsMagnification else { return }
            let phase = fields["phase"]
            if phase == nil || phase == "began" {
                NotificationCenter.default.post(name: NSScrollView.willStartLiveMagnifyNotification, object: scroll)
            }
            scroll.setMagnification(scroll.magnification * (1 + number("amount")), centeredAt: scroll.contentView.convert(at, from: nil))
            if phase == nil || phase == "ended" {
                NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
            }
        default:
            NSLog("DevInput: unknown kind \(fields["kind"] ?? "nil")")
        }
    }
}
