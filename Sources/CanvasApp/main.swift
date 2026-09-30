import AppKit
import CanvasCore
import GhosttyTerminal

// A Canvas 0.2 install's boards, settings and browser profile, moved once, before anything reads
// AppPaths or the defaults (LegacyMigration). Never for a development home, and not while Canvas
// is running (it would still be writing there): the next launch after it quits moves them.
if ProcessInfo.processInfo.environment["CHALKWORK_HOME"] == nil, ProcessInfo.processInfo.environment["CANVAS_HOME"] == nil {
    if NSRunningApplication.runningApplications(withBundleIdentifier: LegacyMigration.legacyBundle).isEmpty {
        for line in LegacyMigration(home: FileManager.default.homeDirectoryForCurrentUser).run(defaults: UserDefaults.standard) {
            NSLog("Chalkwork: %@", line)
        }
    } else {
        NSLog("Chalkwork: Canvas is running, so its boards stay with it; quit it and open Chalkwork again to bring them here")
    }
}

if ProcessInfo.processInfo.environment["CHALKWORK_TERMINAL_DEBUG"] == "1" {
    TerminalDebugLog.sink = { message in FileHandle.standardError.write(Data((message + "\n").utf8)) }
    TerminalDebugLog.enable([.lifecycle, .actions])
}

let app = CanvasApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
