import AppKit
import CanvasCore
import GhosttyTerminal

// An install under an earlier name (Chalkwork 0.3, Canvas 0.2): its boards, settings and browser
// profile, moved once, before anything reads AppPaths or the defaults (LegacyMigration). Never for
// a development home (CANVAS_HOME, or an earlier name's), and not while an earlier app is running
// (it would still be writing there): the next launch after it quits moves them.
do {
    let environment = ProcessInfo.processInfo.environment
    let account = FileManager.default.homeDirectoryForCurrentUser
    if !([LegacyMigration.current] + LegacyMigration.earlier).contains(where: { environment["\($0.slug.uppercased())_HOME"] != nil }) {
        let migration = LegacyMigration(home: account)
        if !migration.pending(defaults: UserDefaults.standard).isEmpty {
            let others = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() }.compactMap(\.bundleIdentifier)
            for line in migration.refusal(running: others).map({ [$0] }) ?? migration.run(defaults: UserDefaults.standard) {
                NSLog("Canvas: %@", line)
            }
        }
    } else if let fake = environment["HOME"].map({ URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }), fake != account.standardizedFileURL,
              let home = environment["CANVAS_HOME"],
              URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL == LegacyMigration(home: fake).support(LegacyMigration.current).standardizedFileURL {
        // An upgrade rehearsal on a throwaway home (docs/testing.md): HOME is that home, CANVAS_HOME
        // its default support directory. UserDefaults ignores HOME, so the migration reads and writes
        // that home's Library/Preferences plists itself, never the user's; no earlier app writes there.
        for line in LegacyMigration(home: fake).run(defaults: PreferenceFiles(home: fake)) {
            NSLog("Canvas (rehearsal on %@): %@", fake.path, line)
        }
    }
}

// One instance per support directory: a second would take over the first's sockets. It hands the
// root it was asked to open to the running instance, brings that one forward, and exits. After the
// migration, which may move another support directory to this one's place.
guard let instanceLock = InstanceLock.acquire(at: AppPaths.instanceLock) else {
    let holder = InstanceLock.holder(at: AppPaths.instanceLock)
    if let root = AppDelegate.requestedRoot() {
        do {
            let reply = try InstanceLock.forward(root: root.standardizedFileURL.path, to: AppPaths.apiSocket)
            if reply["ok"]?.bool != true { NSLog("Canvas: the running instance could not open %@: %@", root.path, "\(reply)") }
        } catch {
            NSLog("Canvas: could not hand %@ to the running instance (pid %@): %@", root.path, holder.map { "\($0)" } ?? "?", "\(error)")
        }
    }
    // Only a running Canvas: the pid may be a previous holder's, reused since (`holder`).
    if ProcessInfo.processInfo.environment["CANVAS_NO_ACTIVATE"] != "1", let holder, let running = NSRunningApplication(processIdentifier: holder),
       running.executableURL?.lastPathComponent == Bundle.main.executableURL?.lastPathComponent {
        running.activate()
    }
    NSLog("Canvas: another instance is running on %@; handed over to it", AppPaths.support.path)
    exit(0)
}

if ProcessInfo.processInfo.environment["CANVAS_TERMINAL_DEBUG"] == "1" {
    TerminalDebugLog.sink = { message in FileHandle.standardError.write(Data((message + "\n").utf8)) }
    TerminalDebugLog.enable([.lifecycle, .actions])
}

let app = CanvasApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
