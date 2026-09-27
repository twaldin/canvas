import Foundation

/// Spreads a burst of main-actor work over run-loop turns. Background results for dozens of
/// tiles (a batch creating 65 code tiles: their models and cards) arrive together, and each
/// installs on the main actor; run back to back they froze the window for most of a second.
/// `next()` resumes one waiter per main-queue turn, in arrival order, so input, timers, and
/// drawing run between them.
@MainActor
enum MainTurns {
    private static var waiting: [CheckedContinuation<Void, Never>] = []
    private static var scheduled = false

    /// Returns on a main-queue turn of its own, after everything already waiting.
    static func next() async {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            schedule()
        }
    }

    /// A block enqueued while the main queue drains runs in its next drain, after the run
    /// loop's input and display phases; a resumed main-actor task is enqueued the same way.
    private static func schedule() {
        guard !scheduled, !waiting.isEmpty else { return }
        scheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                scheduled = false
                waiting.removeFirst().resume()
                schedule()
            }
        }
    }
}
