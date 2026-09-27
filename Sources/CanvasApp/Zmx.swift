import CanvasCore
import Foundation

/// zmx, which keeps terminal tiles' sessions (`AppPaths.zmx`). Every call blocks until zmx
/// exits: call them off the main actor.
enum Zmx {
    /// Runs zmx with `arguments`, handing `consume` its output chunk by chunk while it writes
    /// (it blocks once the pipe buffer fills, so waiting first would deadlock). False when zmx is
    /// missing, doesn't start, or fails.
    @discardableResult
    static func run(_ arguments: [String], _ consume: (Data) -> Void) -> Bool {
        guard let zmx = AppPaths.zmx else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let reader = output.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty { consume(chunk) }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// `zmx list`: a line per running session, any instance's (`name=<session>\tpid=…\t…`, the
    /// current one marked `*`); nil when zmx is missing or fails.
    static func list() -> String? {
        var data = Data()
        guard run(["list"], { data.append($0) }) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
