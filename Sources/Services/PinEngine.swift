import Dispatch
import Foundation
import os

/// Streams the selected trees into rclone's VFS cache. This is cache warming, not
/// an eviction-proof lease: rclone's cache policy may subsequently evict these bytes.
enum PinEngine {
    static func pin(
        roots: [URL],
        mountPath: String,
        relativePaths: [String],
        maximumConcurrentFiles: Int = 3,
        progress: @escaping @Sendable (PinProgress) -> Void
    ) async throws -> PinResult {
        try await run(roots: roots, mountPath: mountPath, relativePaths: relativePaths,
                      maximumConcurrentFiles: maximumConcurrentFiles, progress: progress)
    }

    /// Internal injection surface used by the offline tests/optional benchmark.
    static func run(
        roots: [URL],
        mountPath: String,
        relativePaths: [String],
        maximumConcurrentFiles: Int = 3,
        hooks: PinIOHooks = PinIOHooks(),
        progress: @escaping @Sendable (PinProgress) -> Void
    ) async throws -> PinResult {
        try Task.checkCancellation()
        let concurrency = min(4, max(1, maximumConcurrentFiles))
        let cancellation = PinCancellation()
        let coordinator = PinCoordinator(roots: roots, mountPath: mountPath,
                                         relativePaths: relativePaths, workers: concurrency,
                                         cancellation: cancellation, hooks: hooks, progress: progress)
        coordinator.start()
        return try await withTaskCancellationHandler {
            // Fixed long-lived tasks supply backpressure: each worker asks for only
            // one open file, reads it, closes it, and then asks for another.
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<concurrency {
                    group.addTask {
                        await PinFileIO.worker(coordinator: coordinator, cancellation: cancellation,
                                               hooks: hooks, index: index)
                    }
                }
                await group.waitForAll()
            }
            try Task.checkCancellation()
            return coordinator.result()
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// Native allocated locks make the shared state Sendable without custom unchecked
/// wrappers. Cursor filesystem calls happen on the dedicated worker queues; the
/// separate progress lock never holds up on directory enumeration.
final class PinCoordinator: Sendable {
    private struct ScanState: Sendable {
        var cursor: PinTraversal?
        var initialized = false
        var remainingWorkers: Int
        var pinnedPaths = Set<String>()
    }
    private struct ProgressState {
        var snapshot: PinProgress
        var lastReport: UInt64 = 0
    }

    private let scan: OSAllocatedUnfairLock<ScanState>
    private let updates: OSAllocatedUnfairLock<ProgressState>
    private let roots: [URL]
    private let mountPath: String
    private let relativePaths: [String]
    private let cancellation: PinCancellation
    private let hooks: PinIOHooks
    private let progress: @Sendable (PinProgress) -> Void
    private let startedAt: Date

    init(roots: [URL], mountPath: String, relativePaths: [String], workers: Int,
         cancellation: PinCancellation, hooks: PinIOHooks,
         progress: @escaping @Sendable (PinProgress) -> Void) {
        self.roots = roots
        self.mountPath = mountPath
        self.relativePaths = relativePaths
        self.cancellation = cancellation
        self.hooks = hooks
        self.progress = progress
        startedAt = Date()
        var snapshot = PinProgress()
        snapshot.startedAt = startedAt
        scan = OSAllocatedUnfairLock(initialState: ScanState(remainingWorkers: workers))
        updates = OSAllocatedUnfairLock(initialState: ProgressState(snapshot: snapshot))
    }

    func start() {
        updates.withLock { state in
            state.lastReport = DispatchTime.now().uptimeNanoseconds
            progress(state.snapshot)
        }
    }

    func next() -> PinFileWork? {
        let (file, failures) = scan.withLock { state -> (PinFileWork?, Int) in
            var initialFailures = 0
            if !state.initialized {
                state.initialized = true
                state.cursor = PinTraversal(roots: roots, mountPath: mountPath,
                                            relativePaths: relativePaths,
                                            cancellation: cancellation, hooks: hooks)
                initialFailures = state.cursor?.failedFiles ?? 0
            }
            let before = state.cursor?.failedFiles ?? 0
            let file = state.cursor?.next()
            return (file, initialFailures + (state.cursor?.failedFiles ?? 0) - before)
        }
        update(files: 0, bytes: 0, failures: failures, path: file?.path)
        return file
    }

    func read(bytes: Int64, path: String) {
        update(files: 0, bytes: bytes, failures: 0, path: path)
    }

    func finished(file: PinFileWork, success: Bool) {
        if cancellation.isCancelled { return }
        if !success {
            scan.withLock { $0.cursor?.readFailed(path: file.path) }
        }
        update(files: success ? 1 : 0, bytes: 0, failures: success ? 0 : 1, path: file.path)
    }

    /// Called on a worker queue, before its continuation is resumed. The last
    /// worker closes the traversal stack, including cancellation's unfinished dirs.
    func workerEnded() {
        scan.withLock { state in
            state.remainingWorkers -= 1
            if state.remainingWorkers == 0 {
                state.pinnedPaths = state.cursor?.pinnedPaths ?? []
                state.cursor?.close()
                state.cursor = nil
            }
        }
    }

    func result() -> PinResult {
        let pinned = scan.withLock { $0.pinnedPaths }
        return updates.withLock { state in
            state.snapshot.phase = .finishing
            progress(state.snapshot)
            return PinResult(filesRead: state.snapshot.completedFiles,
                             bytesRead: state.snapshot.completedBytes,
                             failedFiles: state.snapshot.failedFiles, pinnedPaths: pinned,
                             duration: Date().timeIntervalSince(startedAt))
        }
    }

    private func update(files: Int, bytes: Int64, failures: Int, path: String?) {
        updates.withLock { state in
            state.snapshot.completedFiles += files
            state.snapshot.completedBytes += bytes
            state.snapshot.failedFiles += failures
            if let path {
                state.snapshot.currentPath = path
                state.snapshot.phase = .caching
            }
            let now = DispatchTime.now().uptimeNanoseconds
            // Serialized callbacks, <=5/sec plus start/finish. Small files do not
            // enqueue one UI task per file. The final snapshot includes all totals.
            if now - state.lastReport >= 200_000_000 {
                state.lastReport = now
                progress(state.snapshot)
            }
        }
    }
}
