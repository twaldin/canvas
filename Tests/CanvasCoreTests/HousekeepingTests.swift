import Foundation
import Testing
import CanvasCore

/// Launch cleanup deletes only Canvas's own leftovers (footprint study F7, F8: 343 dead Canvas
/// zmx logs, 308 Ghostty config copies, 181 renders), never a file of another name beside them.
struct HousekeepingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func file(_ name: String, age: TimeInterval) -> Housekeeping.File { .init(name: name, modified: now.addingTimeInterval(-age)) }

    @Test func onlyDeadCanvasSessionsLogsGo() {
        let hour: TimeInterval = 3600
        let files = [
            file("canvas-obj_01M3J0QH7C5C74NVEA.log", age: hour),   // dead
            file("canvas-obj_01M3J1DT8E25540DJN.log", age: hour),   // still running (another instance's too)
            file("canvas-obj_01M3J4B73TTXQ117DB.log", age: 10),     // just started, not listed yet
            file("wt5.log", age: hour),                             // the user's own session
            file("zmx.log", age: hour),
            file("canvas-scratch.log", age: hour),                  // not a tile's session name
            file("canvas-obj_01M3J0QH7C5C74NVEA.log.1", age: hour),
        ]
        let live = Housekeeping.sessionNames(zmxList: "name=canvas-obj_01M3J1DT8E25540DJN\tpid=4242\tclients=0\tcanvas.home=x\n*name=wt5\tpid=77\n")
        #expect(live == ["canvas-obj_01M3J1DT8E25540DJN", "wt5"])
        #expect(Housekeeping.deadSessionLogs(files, live: live, now: now) == ["canvas-obj_01M3J0QH7C5C74NVEA.log"])
    }

    @Test func ghosttyConfigsGoOnceRead() {
        let files = [
            file("ghostty-config-00C42C48-4A73-4366-BF1A-6A9029E1B5A7.conf", age: 3600),
            file("ghostty-config-01E9B36D-26BE-4486-9C61-06AAAA5C4CD5.conf", age: 5),   // being loaded
            file("ghostty-config-mine.conf", age: 3600),
            file("config", age: 3600),
        ]
        #expect(Housekeeping.staleGhosttyConfigs(files, now: now) == ["ghostty-config-00C42C48-4A73-4366-BF1A-6A9029E1B5A7.conf"])
    }

    @Test func rendersOlderThanADayGo() {
        let day: TimeInterval = 24 * 3600
        let files = [
            file("render-1790488042161-1.png", age: day + 1),
            file("snapshot-1790488232903-2.jpg", age: 2 * day),
            file("screenshot-1790488232999-4312.png", age: 2 * day),   // canvas browser screenshot
            file("render-1790489399701-1.png", age: day - 60),   // today's
            file("render-final.png", age: 2 * day),               // an agent's own name
            file("notes.txt", age: 2 * day),
        ]
        #expect(Housekeeping.staleRenders(files, now: now) == ["render-1790488042161-1.png", "snapshot-1790488232903-2.jpg", "screenshot-1790488232999-4312.png"])
    }
}
