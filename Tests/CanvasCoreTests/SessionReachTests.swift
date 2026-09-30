import Foundation
import Testing
import CanvasCore

/// A tile waits for a session whose daemon doesn't answer (a stopped zmx daemon at launch) and
/// attaches once it does, instead of failing the attach and staying detached.
struct SessionReachTests {
    let session = "canvas-obj_01M3MWD38ZV1P794MV"

    /// Runs the prologue, then `echo attached`, against a stand-in zmx whose `list` shows the
    /// session unreachable for its first `unreachable` calls (and another session unreachable always).
    func run(unreachable: Int, limit: Int) throws -> (status: Int32, output: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zmx = dir.appendingPathComponent("zmx")
        try """
        #!/bin/sh
        n=$(cat "\(dir.path)/calls" 2>/dev/null || echo 0); echo $((n + 1)) > "\(dir.path)/calls"
        printf 'name=\(session)x\\terr=Timeout\\tstatus=unreachable\\n'
        if [ "$n" -lt \(unreachable) ]; then printf '  name=\(session)\\terr=Timeout\\tstatus=unreachable\\n'
        else printf '  name=\(session)\\tpid=4242\\tclients=0\\tcanvas.home=x\\n'; fi
        """.write(to: zmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zmx.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SessionReach.prologue(limit: limit) + "echo attached", "canvas-attach", zmx.path, session]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func aSessionThatAnswersAttachesAtOnce() throws {
        let (status, output) = try run(unreachable: 0, limit: 1)
        #expect(status == 0)
        #expect(output == "attached\n", "another session not answering doesn't hold this one")
    }

    @Test func aSessionNotAnsweringIsWaitedForAndAttachedWhenItAnswers() throws {
        let (status, output) = try run(unreachable: 1, limit: 60)
        #expect(status == 0)
        #expect(output.contains("This terminal session (\(session)) is not answering (its process may be stopped); retrying in 1s"))
        #expect(output.hasSuffix("attached\n"))
    }

    @Test func waitingIsBoundedAndSaysSo() throws {
        let (status, output) = try run(unreachable: .max, limit: 1)
        #expect(status == 1)
        #expect(output.contains("still is not answering. Press any key to try again."))
        #expect(!output.contains("attached"))
    }
}
