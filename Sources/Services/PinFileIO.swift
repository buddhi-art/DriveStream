import Darwin
import Dispatch
import Foundation
import os

/// Hooks are per-operation, never global. Tests can inject failures/latency without a mount.
struct PinIOHooks: Sendable {
    var beforeRead: (@Sendable (String) -> Void)?
    var failRead: (@Sendable (String) -> Bool)?
    var failEnumeration: (@Sendable (String) -> Bool)?
    var readerActivity: (@Sendable (Int) -> Void)?
    var descriptorActivity: (@Sendable (Int) -> Void)?
}

final class PinCancellation: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
}

/// One block per worker, not per file/chunk. Blocking filesystem work never occupies
/// the MainActor or Swift's cooperative executor. Each worker owns its buffer and fd.
enum PinFileIO {
    static let chunkSize = 4 * 1024 * 1024

    static func worker(
        coordinator: PinCoordinator,
        cancellation: PinCancellation,
        hooks: PinIOHooks,
        index: Int
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "app.drivestream.pin.io.\(index)", qos: .utility)
            queue.async {
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 4096)
                defer {
                    buffer.deallocate()
                    coordinator.workerEnded()
                    continuation.resume()
                }
                while !cancellation.isCancelled, let file = coordinator.next() {
                    hooks.readerActivity?(1)
                    let success = read(file, buffer: buffer, coordinator: coordinator,
                                       cancellation: cancellation, hooks: hooks)
                    // Only the owner closes the fd: cross-thread close does not reliably
                    // interrupt a kernel read, and can race descriptor reuse.
                    Darwin.close(file.descriptor)
                    hooks.descriptorActivity?(-1)
                    hooks.readerActivity?(-1)
                    coordinator.finished(file: file, success: success)
                }
            }
        }
    }

    private static func read(
        _ file: PinFileWork,
        buffer: UnsafeMutableRawPointer,
        coordinator: PinCoordinator,
        cancellation: PinCancellation,
        hooks: PinIOHooks
    ) -> Bool {
        var total: Int64 = 0
        while !cancellation.isCancelled {
            hooks.beforeRead?(file.path)
            if cancellation.isCancelled { return false }
            if hooks.failRead?(file.path) == true { return false }
            let count = Darwin.read(file.descriptor, buffer, chunkSize)
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            if count == 0 {
                var final = stat()
                guard fstat(file.descriptor, &final) == 0 else { return false }
                // Do not mark a truncated/growing/modified file complete. An offline
                // marker is a successful read snapshot, not a filesystem lease.
                return total == file.size && final.st_size == file.size
                    && final.st_mtimespec.tv_sec == file.modifiedSeconds
                    && final.st_mtimespec.tv_nsec == file.modifiedNanoseconds
            }
            total += Int64(count)
            coordinator.read(bytes: Int64(count), path: file.path)
        }
        return false
    }
}
