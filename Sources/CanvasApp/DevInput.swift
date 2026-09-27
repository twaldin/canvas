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
            DevPerf.begin("burst of \(count) \(fields["kind"] ?? "")", phase: "gesture", window: frontWindow())
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
                    DevPerf.phase("settle")
                    DispatchQueue.main.asyncAfter(deadline: .now() + DevPerf.settle) { MainActor.assumeIsolated { DevPerf.end() } }
                }
            }
            timer.resume()
            return
        }
        if fields["kind"] == "perf" {
            // A performance probe span over an idle stretch (DevPerf): what redraws and runs while
            // nobody touches the app, also with the window minimized or covered (no frames then).
            let window = frontWindow() ?? NSApp.windows.first { $0.windowController is CanvasWindowController }
            return DevPerf.idle(ms: Double(fields["ms"] ?? "") ?? 5000, window: window)
        }
        guard let window = frontWindow(), let content = window.contentView else { return }
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
        case "menu":
            // A shown context menu runs a tracking loop posted events can't drive: build the menu
            // a right-click at x,y would show (the hit view, then its superviews) and perform the
            // item at `path`, titles separated by "/" (e.g. "Scale/150%").
            let at = point("x", "y")
            guard let frame = content.superview, let hit = content.hitTest(frame.convert(at, from: nil)),
                  let event = NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            var menu = sequence(first: hit, next: \.superview).lazy.compactMap { $0.menu(for: event) }.first
            var titles = (fields["path"] ?? "").split(separator: "/").map(String.init)
            while let current = menu, !titles.isEmpty {
                let title = titles.removeFirst()
                guard let index = current.items.firstIndex(where: { $0.title == title }) else {
                    return NSLog("DevInput: no menu item %@ in [%@]", title, current.items.map(\.title).joined(separator: ", "))
                }
                if titles.isEmpty { current.performActionForItem(at: index) } else { menu = current.items[index].submenu }
            }
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
            // A burst step is a continuous (trackpad-precise) delta without a gesture phase: on
            // macOS 26 a replayed phased gesture only moves the view by its first step (NSScrollView
            // tracks the rest of a real gesture itself and drops directly delivered steps). A
            // single step is a phaseless wheel notch, which AppKit animates as a smooth scroll.
            if fields["phase"] != nil { cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
            // A window-less event's locationInWindow is its screen location, which only matches the
            // window near the primary display's origin; hand it to the view under the point instead
            // of relying on sendEvent's hit test (windows on other displays got nothing).
            guard let event = NSEvent(cgEvent: cg), let frame = content.superview,
                  let hit = content.hitTest(frame.convert(at, from: nil)) else { return }
            hit.scrollWheel(with: event)
        case "magnify":
            // A trackpad pinch step as a real gesture event: CG type 29 (gesture) with HID type 8
            // (zoom) becomes an NSEvent of type .magnify, so NSScrollView runs its own live
            // magnification (scaled layers mid-gesture, a redraw at the end) exactly as for a pinch.
            guard let cg = CGEvent(source: nil), let type = CGEventType(rawValue: 29),
                  let hidType = CGEventField(rawValue: 110), let zoom = CGEventField(rawValue: 113),
                  let gesturePhase = CGEventField(rawValue: 132) else { return }
            cg.type = type
            cg.setIntegerValueField(hidType, value: 8)
            cg.setDoubleValueField(zoom, value: Double(number("amount")))
            let phases: [String: Int64] = ["began": 1, "changed": 2, "ended": 4]
            cg.setIntegerValueField(gesturePhase, value: phases[fields["phase"] ?? ""] ?? 2)
            let at = point("x", "y")
            // A window-less event's locationInWindow is its Cocoa screen location; make that the
            // replayed point, or the scroll view ignores a pinch that seems to be outside it.
            cg.location = CGPoint(x: at.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - at.y)
            guard let event = NSEvent(cgEvent: cg), event.type == .magnify, let frame = content.superview,
                  let hit = content.hitTest(frame.convert(at, from: nil)) else { return }
            var view: NSView? = hit
            while let current = view, !(current is NSScrollView) { view = current.superview }
            // Live magnification anchors at the real pointer (wherever the user's mouse is), so put
            // the document point that was under the replayed point back under it after each step.
            let clip = (view as? NSScrollView)?.contentView
            let anchor = clip?.convert(at, from: nil)
            hit.magnify(with: event)
            if let clip, let anchor, let scroll = view as? NSScrollView {
                let drift = clip.convert(at, from: nil)
                clip.scroll(to: NSPoint(x: clip.bounds.minX + anchor.x - drift.x, y: clip.bounds.minY + anchor.y - drift.y))
                scroll.reflectScrolledClipView(clip)
            }
        default:
            NSLog("DevInput: unknown kind \(fields["kind"] ?? "nil")")
        }
    }

    /// The front board window: with tabs, the selected tab (the others are ordered out).
    static func frontWindow() -> NSWindow? {
        NSApp.orderedWindows.first { window in
            window.isVisible && window.windowController is CanvasWindowController
                && (window.tabGroup.map { $0.selectedWindow === window } ?? true)
        }
    }
}
