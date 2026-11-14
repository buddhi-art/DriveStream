import Darwin
import Foundation

/// Process mechanics only. MountController retains session ownership, authenticated
/// readiness, write-safety decisions and the right to detach a particular volume.
/// A process exit is never interpreted here as successful cloud upload/detachment.
enum RcloneProcessSupervisor {
    struct StopPolicy: Sendable {
        let interruptWait: TimeInterval
        let terminateWait: TimeInterval
        let killWait: TimeInterval

        static let normal = StopPolicy(interruptWait: 12, terminateWait: 4, killWait: 3)
        static let failedStartup = StopPolicy(interruptWait: 6, terminateWait: 3, killWait: 2)
    }

    @MainActor
    static func launch(
        executableURL: URL, arguments: [String], workingDirectory: URL,
        rcPassword: String, onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> Process {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        // The mount writes through --log-file, not an unread kernel pipe.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessLaunchEnvironment.make(overrides: ["RCLONE_RC_PASS": rcPassword])
        process.qualityOfService = .userInitiated
        process.terminationHandler = { onTermination($0.terminationStatus) }
        try Task.checkCancellation()
        try process.run()
        return process
    }

    /// A fresh, joined worker deliberately finishes bounded teardown even when its
    /// caller has been cancelled. It operates on the exact owned Process, not a name
    /// search or a PID acquired from a different mount session.
    static func stop(_ process: Process, policy: StopPolicy) async -> Bool {
        await Task.detached(priority: .utility) {
            if process.isRunning { process.interrupt() }
            if await waitForExit(process, timeout: policy.interruptWait) { return true }
            if process.isRunning { process.terminate() }
            if await waitForExit(process, timeout: policy.terminateWait) { return true }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return await waitForExit(process, timeout: policy.killWait)
        }.value
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
        return !process.isRunning
    }

    static func pauseDuringCleanup(seconds: TimeInterval) async {
        await Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
        }.value
    }

    static func createLog(paths: DriveStreamPaths, backend: VolumeBackend) throws -> URL {
        try paths.prepareFileSystem()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let name = "rclone-\(stamp)-\(backend.rawValue.lowercased())-\(UUID().uuidString).log"
        let log = paths.logsDirectory.appendingPathComponent(name)
        try ServiceFileSafety.createPrivateFile(log)
        pruneLogs(in: paths.logsDirectory, keeping: log)
        return log
    }

    static func logExcerpt(at url: URL?, limit: Int) -> String {
        guard limit > 0, let url, let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let length = min(limit, 64 * 1024)
        let start = end > UInt64(length) ? end - UInt64(length) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.read(upToCount: length)) ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pruneLogs(in directory: URL, keeping current: URL) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let logs = entries.filter {
            $0.lastPathComponent.hasPrefix("rclone-") && $0.pathExtension == "log"
                && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
        }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for entry in logs.dropFirst(20) where entry != current {
            guard entry.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL else { continue }
            try? manager.removeItem(at: entry)
        }
    }
}
