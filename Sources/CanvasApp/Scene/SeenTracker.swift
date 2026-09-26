import Foundation
import CanvasCore

/// "Seen" by dwell: an object that stays visible (readable zoom, key window) for `dwell` seconds
/// counts as seen. Driven by the canvas's coalesced scene passes plus one timer for the earliest
/// pending deadline, never by polling.
@MainActor
final class SeenTracker {
    static let dwell: TimeInterval = 3

    private var since: [ObjectID: TimeInterval] = [:]
    private var timer: DispatchWorkItem?
    private let onSeen: (ObjectID) -> Void

    init(onSeen: @escaping (ObjectID) -> Void) {
        self.onSeen = onSeen
    }

    /// The objects visible right now; those that stay visible become seen after the dwell.
    func update(visible: Set<ObjectID>) {
        let now = ProcessInfo.processInfo.systemUptime
        since = since.filter { visible.contains($0.key) }
        for id in visible where since[id] == nil { since[id] = now }
        reschedule(now: now)
    }

    private func reschedule(now: TimeInterval) {
        timer?.cancel()
        timer = nil
        guard let earliest = since.values.min() else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, earliest + Self.dwell - now), execute: item)
    }

    private func fire() {
        let now = ProcessInfo.processInfo.systemUptime
        let due = since.filter { now - $0.value >= Self.dwell }.map(\.key)
        for id in due { since.removeValue(forKey: id) }
        reschedule(now: now)
        due.forEach(onSeen)
    }
}
