import Foundation

public enum GitError: Error, Equatable, Sendable {
    case launch(String)
    case failed(status: Int32, stderr: String)
    /// stdout passed the caller's `maxOutput`; git was stopped.
    case outputTooLarge
}

/// Runs git with an app-wide cap on concurrent processes (docs/design.md, Performance). Every
/// git invocation in the app goes through `shared`.
public actor GitRunner {
    public static let shared = GitRunner(limit: 2)

    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = limit
    }

    /// stdout of `git <args>` run in `directory`. Exit codes outside `allowedStatus` throw
    /// `GitError.failed` with git's stderr; more than `maxOutput` bytes of stdout stops git and
    /// throws `GitError.outputTooLarge`.
    public func run(_ args: [String], in directory: URL, allowedStatus: Set<Int32> = [0], maxOutput: Int = .max) async throws -> Data {
        await acquire()
        defer { release() }
        let result = try await Self.spawn(args, in: directory, maxOutput: maxOutput)
        guard allowedStatus.contains(result.status) else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.failed(status: result.status, stderr: message)
        }
        return result.stdout
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the slot straight to the next waiter so a burst can't overshoot the cap.
    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    private final class Output: @unchecked Sendable {
        var stderr = Data()
    }

    private static func spawn(_ args: [String], in directory: URL, maxOutput: Int) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                // Paths print verbatim; no pager, prompts, or optional index locks that would
                // contend with the agents working in the same repository.
                process.arguments = ["-c", "core.quotepath=off", "--no-pager"] + args
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                environment["GIT_OPTIONAL_LOCKS"] = "0"
                environment["GIT_TERMINAL_PROMPT"] = "0"
                process.environment = environment
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: GitError.launch(error.localizedDescription))
                    return
                }
                // Drain stderr alongside stdout so neither pipe can fill up and stall git.
                let output = Output()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    output.stderr = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                var data = Data()
                let reader = stdout.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    if data.count > maxOutput {
                        process.terminate()
                        _ = reader.readDataToEndOfFile()
                        group.wait()
                        process.waitUntilExit()
                        continuation.resume(throwing: GitError.outputTooLarge)
                        return
                    }
                }
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, data, output.stderr))
            }
        }
    }
}

/// Runs blocking work (file reads, parsing large files) on GCD rather than a Swift concurrency
/// thread: the cooperative pool is only as wide as the core count, and parking it starves the
/// socket servers' request tasks.
public func offPool<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
    }
}
