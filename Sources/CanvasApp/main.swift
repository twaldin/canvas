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

// One instance per support directory: a second would take over the first's sockets. It hands the
// root it was asked to open to the running instance, brings that one forward, and exits. After the
// migration, which moves the legacy support directory only while this one doesn't exist yet.
guard let instanceLock = InstanceLock.acquire(at: AppPaths.instanceLock) else {
    let holder = InstanceLock.holder(at: AppPaths.instanceLock)
    if let root = AppDelegate.requestedRoot() {
        do {
            let reply = try InstanceLock.forward(root: root.standardizedFileURL.path, to: AppPaths.apiSocket)
            if reply["ok"]?.bool != true { NSLog("Chalkwork: the running instance could not open %@: %@", root.path, "\(reply)") }
        } catch {
            NSLog("Chalkwork: could not hand %@ to the running instance (pid %@): %@", root.path, holder.map { "\($0)" } ?? "?", "\(error)")
        }
    }
    // Only a running Chalkwork: the pid may be a previous holder's, reused since (`holder`).
    if ProcessInfo.processInfo.environment["CHALKWORK_NO_ACTIVATE"] != "1", let holder, let running = NSRunningApplication(processIdentifier: holder),
       running.executableURL?.lastPathComponent == Bundle.main.executableURL?.lastPathComponent {
        running.activate()
    }
    NSLog("Chalkwork: another instance is running on %@; handed over to it", AppPaths.support.path)
    exit(0)
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
