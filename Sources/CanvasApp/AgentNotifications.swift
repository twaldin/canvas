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
    /// Last announced "state|message" per tile, so repeated reports of the same state stay quiet.
    private var announced: [ObjectID: String] = [:]
    private var delivered: Set<ObjectID> = []

    func install() {
        guard enabled else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func observe(_ event: BoardEvent, on board: Board) {
        switch event {
        case .agentLifecycle(let id, let lifecycle):
            let state = lifecycle["state"]?.string
            guard state == LifecycleState.done.rawValue || state == LifecycleState.blocked.rawValue,
                  let terminal = board.objects[id] else {
                announced.removeValue(forKey: id)
                withdraw(id)
                return
            }
            let message = lifecycle["message"]?.string
            let key = "\(state ?? "")|\(message ?? "")"
            guard announced[id] != key else { return }
            announced[id] = key
            guard !NSApp.isActive else { return }
            post(tile: terminal, board: board, blocked: state == LifecycleState.blocked.rawValue, message: message)
        case .objectDeleted(let id):
            announced.removeValue(forKey: id)
            withdraw(id)
        default:
            return
        }
    }

    private func post(tile terminal: CanvasObject, board: Board, blocked: Bool, message: String?) {
        let name = terminal.props["name"]?.string ?? TileFrameView.title(for: terminal)
        let content = UNMutableNotificationContent()
        content.title = blocked ? "\(name) needs you" : "\(name) is done"
        content.subtitle = board.root.lastPathComponent
        content.body = message ?? (blocked ? "Waiting for your answer." : "Finished and waiting for your next prompt.")
        content.userInfo = ["board": board.id, "tile": terminal.id]
        guard enabled else {
            NSLog("Canvas: notification suppressed (CANVAS_NO_ACTIVATE): %@ — %@", content.title, content.body)
            return
        }
        // One notification per tile: a newer state replaces the older one.
        let request = UNNotificationRequest(identifier: "agent.\(terminal.id)", content: content, trigger: nil)
        delivered.insert(terminal.id)
        Task {
            guard await self.authorize() else { return }
            try? await UNUserNotificationCenter.current().add(request)
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

extension CanvasView {
    /// Centers the tile at 100%, selects it, and gives a terminal keyboard focus.
    func focus(tile id: ObjectID) {
        guard let tile = tiles[id] else { return }
        magnification = 1
        let visible = documentVisibleRect
        contentView.scroll(to: NSPoint(x: tile.frame.midX - visible.width / 2, y: tile.frame.midY - visible.height / 2))
        reflectScrolledClipView(contentView)
        select(id, extend: false)
    }
}
