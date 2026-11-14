import Darwin
import Foundation

struct CommandResult: Sendable {
    let executable: String
    let arguments: [String]
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
    let duration: TimeInterval

    var succeeded: Bool { exitCode == 0 && !timedOut }
    var combinedOutput: String {
        [standardOutput, standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
    var outputTail: String { String(combinedOutput.suffix(3_000)) }
}

enum CommandRunnerError: LocalizedError {
    case couldNotLaunch(executable: String, reason: String)
    case timedOut(CommandResult)
    case failed(CommandResult)
    case outputLimitExceeded

    // Helper output can contain OAuth tokens, passwords, or private file names.
    // Keep captured output available to parsers, but NEVER render it in errors.
    var errorDescription: String? {
        switch self {
        case .couldNotLaunch(let executable, _):
            return "Could not launch \(URL(fileURLWithPath: executable).lastPathComponent)."
        case .timedOut(let result): return "\(result.executable) timed out."
        case .failed(let result): return "\(result.executable) exited with status \(result.exitCode)."
        case .outputLimitExceeded: return "The helper exceeded its output limit."
        }
    }
}

/// Short-lived helpers use private files, never pipes or waitUntilExit. The detached
/// worker is explicitly cancelled with its parent, and joined after bounded shutdown.
enum CommandRunner {
    static let maximumOutputBytes = 4 * 1024 * 1024

    static func run(
        executable: String,
        arguments: [String] = [],
        timeout: TimeInterval = 120,
        input: String? = nil,
        environment: [String: String]? = nil
    ) async throws -> CommandResult {
        let worker = Task.detached(priority: .utility) {
            try await execute(executable: executable, arguments: arguments,
                              timeout: timeout, input: input, environment: environment)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    private static func execute(
        executable: String, arguments: [String], timeout: TimeInterval,
        input: String?, environment: [String: String]?
    ) async throws -> CommandResult {
        try Task.checkCancellation()
        let directory = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-command-")
        defer { ServiceFileSafety.removeTemporaryDirectory(directory, prefix: "DriveStream-command-") }
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        try ServiceFileSafety.createPrivateFile(stdout)
        try ServiceFileSafety.createPrivateFile(stderr)
        let stdoutHandle = try FileHandle(forWritingTo: stdout)
        let stderrHandle = try FileHandle(forWritingTo: stderr)
        var stdinHandle: FileHandle?
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? stdinHandle?.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable.contains("/") ? executable : "/usr/bin/env")
        process.arguments = executable.contains("/") ? arguments : [executable] + arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        if let input {
            let stdin = directory.appendingPathComponent("stdin")
            try ServiceFileSafety.createPrivateFile(stdin, data: Data(input.utf8))
            stdinHandle = try FileHandle(forReadingFrom: stdin)
            process.standardInput = stdinHandle
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.environment = ProcessLaunchEnvironment.make(overrides: environment)
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let start = clock.now
        do { try process.run() }
        catch { throw CommandRunnerError.couldNotLaunch(executable: executable, reason: error.localizedDescription) }
        let deadline = start.advanced(by: .seconds(timeout.isFinite ? max(timeout, 0.1) : 120))
        var timedOut = false
        do {
            while process.isRunning {
                try Task.checkCancellation()
                try checkOutputSize(stdout)
                try checkOutputSize(stderr)
                if clock.now >= deadline { timedOut = true; break }
                try await Task.sleep(for: .milliseconds(40))
            }
        } catch {
            await stop(process)
            throw error
        }
        if timedOut { await stop(process) }
        try Task.checkCancellation()
        try checkOutputSize(stdout)
        try checkOutputSize(stderr)
        let elapsed = start.duration(to: clock.now).components
        let result = CommandResult(
            executable: URL(fileURLWithPath: executable).lastPathComponent,
            arguments: arguments, exitCode: process.isRunning ? -1 : process.terminationStatus,
            standardOutput: try readBounded(stdout), standardError: try readBounded(stderr),
            timedOut: timedOut,
            duration: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        )
        if timedOut { throw CommandRunnerError.timedOut(result) }
        if !result.succeeded { throw CommandRunnerError.failed(result) }
        return result
    }

    private static func stop(_ process: Process) async {
        // A fresh, joined task is not cancelled: cleanup sleeps cannot turn into a
        // busy-loop, and no detached helper is left running when run() returns.
        await Task.detached(priority: .utility) {
            guard process.isRunning else { return }
            process.terminate()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while process.isRunning && clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                let killDeadline = clock.now.advanced(by: .seconds(2))
                while process.isRunning && clock.now < killDeadline {
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
        }.value
    }

    private static func checkOutputSize(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if (attributes[.size] as? NSNumber)?.intValue ?? 0 > maximumOutputBytes {
            throw CommandRunnerError.outputLimitExceeded
        }
    }

    private static func readBounded(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumOutputBytes + 1) ?? Data()
        guard data.count <= maximumOutputBytes else { throw CommandRunnerError.outputLimitExceeded }
        return String(decoding: data, as: UTF8.self)
    }
}
