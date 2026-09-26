import Testing
import CanvasCore

struct AgentNoticesTests {
    var notices = AgentNotices()

    /// Reports a lifecycle for `tile` (`nil` state: released or deleted) and returns the notice, if any.
    mutating func report(_ tile: ObjectID, _ state: String?, _ message: String? = nil) -> AgentNotices.Notice? {
        var lifecycle: [String: JSONValue] = [:]
        if let state { lifecycle["state"] = .string(state) }
        if let message { lifecycle["message"] = .string(message) }
        return notices.observe(tile: tile, lifecycle: state == nil ? nil : .object(lifecycle))
    }

    @Test mutating func announcesDoneAndBlockedOncePerState() throws {
        #expect(report("obj_a", "working") == nil)
        let done = try #require(report("obj_a", "done"))
        #expect(!done.blocked)
        #expect(report("obj_a", "done") == nil, "a repeated report stays quiet")
        #expect(notices.isCurrent(done))
        let blocked = try #require(report("obj_a", "blocked", "approve bash?"))
        #expect(blocked.blocked && blocked.message == "approve bash?")
        #expect(!notices.isCurrent(done), "a newer state replaces the older notice")
    }

    @Test mutating func aNewQuestionWhileBlockedIsANewNotice() throws {
        let first = try #require(report("obj_a", "blocked", "approve bash?"))
        let second = try #require(report("obj_a", "blocked", "which branch?"))
        #expect(!notices.isCurrent(first))
        #expect(notices.isCurrent(second))
    }

    @Test mutating func aPendingNoticeGoesStaleWhenTheAgentMovesOn() throws {
        let pending = try #require(report("obj_a", "done"))
        // Authorization is still pending; meanwhile the agent works again and finishes again.
        _ = report("obj_a", "working")
        #expect(!notices.isCurrent(pending))
        #expect(!notices.isAnnounced("obj_a"))
        let again = try #require(report("obj_a", "done"))
        #expect(!notices.isCurrent(pending), "the same state later is a different announcement")
        #expect(notices.isCurrent(again))
    }

    @Test mutating func seenReleasedAndDeletedTilesRetireTheirNotice() throws {
        let seen = try #require(report("obj_a", "done"))
        _ = report("obj_a", "idle")
        #expect(!notices.isCurrent(seen))
        let deleted = try #require(report("obj_b", "blocked"))
        let other = try #require(report("obj_c", "done"))
        _ = report("obj_b", nil)
        #expect(!notices.isCurrent(deleted))
        #expect(notices.isCurrent(other), "tiles are independent")
    }
}
