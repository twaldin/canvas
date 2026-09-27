import AppKit
import CryptoKit
import WebKit

/// The one browser profile every browser tile shares: cookies and logins, local storage and
/// databases, caches. The app keeps WebKit's default store whatever its `CANVAS_HOME` (a
/// developer's everyday instance runs from a development home), so nothing moves for anyone. An
/// instance launched with `CANVAS_BROWSER_PROFILE=own` (`scripts/dev.sh` sets it for a
/// `CANVAS_DEV_HOME`: study and slice instances) gets a persistent store named by its home
/// (`identifier`), so it never shares cookies or storage with the user's app or another
/// instance, and keeps its own across restarts. HTML tiles never use it (their store is
/// non-persistent, `HtmlTile`).
@MainActor
enum BrowserProfile {
    static let store: WKWebsiteDataStore = ProcessInfo.processInfo.environment["CANVAS_BROWSER_PROFILE"] == "own"
        ? WKWebsiteDataStore(forIdentifier: identifier(home: AppPaths.support)) : .default()

    /// The same UUID for the same home directory on every launch (a name-based UUID, RFC 9562
    /// version 5 layout, from SHA-256 of the standardized path), a different one for another.
    nonisolated static func identifier(home: URL) -> UUID {
        let digest = Array(SHA256.hash(data: Data(("net.waldin.canvas.home:" + home.standardizedFileURL.path).utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Canvas › Clear Browsing Data…: says what goes, in a sheet (an app-modal alert would stall
    /// every socket request until answered), then removes all of it from `store`. Pages open now
    /// keep what they show until they reload. `done` runs once the data is gone.
    static func confirmClear(in window: NSWindow, done: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Clear browsing data?"
        alert.informativeText = "Removes every browser tile's cookies and logins, local storage and databases, and cached files, on every board. Pages open now keep what they show until they reload."
        // Return and Esc cancel: this signs you out of every site, so it takes a click.
        alert.addButton(withTitle: "Cancel")
        let clear = alert.addButton(withTitle: "Clear")
        clear.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            Task { @MainActor in
                await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                NSLog("Canvas: cleared browsing data")
                done()
            }
        }
    }
}
