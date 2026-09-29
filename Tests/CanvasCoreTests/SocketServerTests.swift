import Darwin
import Foundation
import Testing
import CanvasCore

/// Two app instances sharing a support dir bind the same socket path in turn.
final class SocketServerTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-\(UUID().uuidString.prefix(8))")
    var path: String { dir.appendingPathComponent("s").path }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// A server that answers every request with its name.
    func start(_ name: String) throws -> SocketServer {
        let server = SocketServer(path: path) { _, _ in .string(name) }
        try server.start()
        return server
    }

    @Test func stoppingLeavesTheSocketAnotherServerBoundThereSince() async throws {
        let first = try start("first")
        let second = try start("second")
        first.stop()

        let client = try LineClient(path: path)
        client.send("{}")
        #expect(try await client.next() == .string("second"))

        second.stop()
        #expect(access(path, F_OK) != 0)
    }
}
