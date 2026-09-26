import AppKit

/// With `CANVAS_NO_ACTIVATE=1` (development and agent testing on a shared machine) the app never
/// activates, so nothing it does can steal focus or switch the user's Space.
final class CanvasApplication: NSApplication {
    static let neverActivate = ProcessInfo.processInfo.environment["CANVAS_NO_ACTIVATE"] == "1"

    override func activate(ignoringOtherApps flag: Bool) {
        if !Self.neverActivate { super.activate(ignoringOtherApps: flag) }
    }

    override func activate() {
        if !Self.neverActivate { super.activate() }
    }
}
