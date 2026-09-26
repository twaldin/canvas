import AppKit
import GhosttyTerminal

if ProcessInfo.processInfo.environment["CANVAS_TERMINAL_DEBUG"] == "1" {
    TerminalDebugLog.sink = { message in FileHandle.standardError.write(Data((message + "\n").utf8)) }
    TerminalDebugLog.enable([.lifecycle, .actions])
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
