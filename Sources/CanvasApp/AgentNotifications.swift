import AppKit
import CanvasCore
import UserNotifications

/// macOS notifications when an agent tile becomes `done` or `blocked` while Canvas isn't
/// frontmost. Clicking one brings its window forward and focuses the tile.
///
/// Authorization is requested lazily, the first time there is something to say. With
/// `CANVAS_NO_ACTIVATE=1` (development instances on a shared machine) nothing is ever requested
/// or posted, so tests can't prompt the user; the decision is logged instead.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((BoardID, ObjectID) -> Void)?
    /// Posting needs a bundled app: `UNUserNotificationCenter.current()` traps without a bundle id.
    private let enabled = ProcessInfo.processInfo.environment["CANVAS_NO_ACTIVATE"] != "1" && Bundle.main.bundleIdentifier != nil
    private var authorized: Bool?
    private var notices = AgentNotices()
    private var delivered: Set<ObjectID> = []

    func install() {
        guard enabled else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func observe(_ event: BoardEvent, on board: Board) {
        let tile: ObjectID
        let notice: AgentNotices.Notice?
        switch event {
        case .agentLifecycle(let id, let lifecycle):
            tile = id
            notice = notices.observe(tile: id, lifecycle: lifecycle)
        case .objectDeleted(let id):
            tile = id
            notice = notices.observe(tile: id, lifecycle: nil)
        default:
            return
        }
        guard let notice else {
            if !notices.isAnnounced(tile) { withdraw(tile) }
            return
        }
        guard !NSApp.isActive, let terminal = board.objects[tile] else { return }
        post(notice, tile: terminal, board: board)
    }

    private func post(_ notice: AgentNotices.Notice, tile terminal: CanvasObject, board: Board) {
        let name = terminal.props["name"]?.string ?? TileFrameView.title(for: terminal)
        let content = UNMutableNotificationContent()
        content.title = notice.blocked ? "\(name) needs you" : "\(name) is done"
        content.subtitle = board.root.lastPathComponent
        content.body = notice.message ?? (notice.blocked ? "Waiting for your answer." : "Finished and waiting for your next prompt.")
        content.userInfo = ["board": board.id, "tile": terminal.id]
        guard enabled else {
            NSLog("Canvas: notification suppressed (CANVAS_NO_ACTIVATE): %@ — %@", content.title, content.body)
            return
        }
        // One notification per tile: a newer state replaces the older one.
        let request = UNNotificationRequest(identifier: "agent.\(terminal.id)", content: content, trigger: nil)
        Task {
            // Authorization can wait on the user; by then the agent may have moved on or the user
            // may have come back to the app.
            guard await self.authorize(), self.notices.isCurrent(notice), !NSApp.isActive else { return }
            self.delivered.insert(notice.tile)
            try? await UNUserNotificationCenter.current().add(request)
            if !self.notices.isCurrent(notice) { self.withdraw(notice.tile) }
        }
    }

    private func authorize() async -> Bool {
        if let authorized { return authorized }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        authorized = granted
        return granted
    }

    /// The agent moved on (working again, seen, closed); its notification is stale.
    private func withdraw(_ tile: ObjectID) {
        guard delivered.remove(tile) != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["agent.\(tile)"])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let board = info["board"] as? String, let tile = info["tile"] as? String {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onOpen?(board, tile) }
            }
        }
        completionHandler()
    }
}
