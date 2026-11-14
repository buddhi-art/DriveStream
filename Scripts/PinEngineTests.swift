import Darwin
import Dispatch
import Foundation
import os

private struct PinTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PinTestFailure(description: message) }
}

private final class Observations: Sendable {
    struct State: Sendable {
        var readers = 0
        var maximumReaders = 0
        var descriptors = 0
        var maximumDescriptors = 0
        var snapshots: [PinProgress] = []
        var times: [UInt64] = []
        var readCalls = 0
    }
    let value = OSAllocatedUnfairLock(initialState: State())
    var state: State { value.withLock { $0 } }
    func hooks(delay: useconds_t = 0) -> PinIOHooks {
        PinIOHooks(beforeRead: { _ in
            self.value.withLock { $0.readCalls += 1 }
            if delay > 0 { usleep(delay) }
        }, readerActivity: { delta in
            self.value.withLock {
                $0.readers += delta
                $0.maximumReaders = max($0.maximumReaders, $0.readers)
            }
        }, descriptorActivity: { delta in
            self.value.withLock {
                $0.descriptors += delta
                $0.maximumDescriptors = max($0.maximumDescriptors, $0.descriptors)
            }
        })
    }
    func record(_ progress: PinProgress) {
        value.withLock {
            $0.snapshots.append(progress)
            $0.times.append(DispatchTime.now().uptimeNanoseconds)
        }
    }
}

private final class ReadSignal: Sendable {
    private struct State: Sendable {
        var fired = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let value = OSAllocatedUnfairLock(initialState: State())
    func fire() {
        let waiter = value.withLock { state -> CheckedContinuation<Void, Never>? in
            state.fired = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = value.withLock { state in
                if state.fired { return true }
                state.waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

private struct Fixtures: Sendable {
    let base: URL
    private let parent: URL
    init() throws {
        parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        base = parent.appendingPathComponent("DriveStream-pin-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    }
    func directory(_ path: String) throws -> URL {
        let url = base.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @discardableResult
    func file(_ path: String, size: Int = 37) throws -> URL {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x6d, count: size).write(to: url)
        return url
    }
    func cleanup() throws {
        let resolved = base.resolvingSymlinksInPath().standardizedFileURL
        let values = try base.resourceValues(forKeys: [.isSymbolicLinkKey])
        try require(resolved.path == base.path && base.deletingLastPathComponent() == parent
                    && base.lastPathComponent.hasPrefix("DriveStream-pin-tests-")
                    && values.isSymbolicLink != true, "Refuse unexpected fixture cleanup")
        try FileManager.default.removeItem(at: base)
    }
}

@main
struct PinEngineTests {
    static func main() async throws {
        let fixtures = try Fixtures()
        do {
            try await run(fixtures)
            try fixtures.cleanup()
        } catch {
            try fixtures.cleanup()
            throw error
        }
    }

    private static func pin(_ fixtures: Fixtures, _ paths: [String],
                            concurrency: Int = 3, hooks: PinIOHooks = PinIOHooks(),
                            progress: @escaping @Sendable (PinProgress) -> Void = { _ in }) async throws -> PinResult {
        try await PinEngine.run(roots: paths.map { fixtures.base.appendingPathComponent($0) },
                                mountPath: fixtures.base.path, relativePaths: paths,
                                maximumConcurrentFiles: concurrency, hooks: hooks, progress: progress)
    }

    private static func run(_ f: Fixtures) async throws {
        _ = try f.directory("empty")
        let empty = try await pin(f, ["empty"])
        try require(empty.filesRead == 0 && empty.failedFiles == 0 && empty.pinnedPaths == ["empty"],
                    "Empty eligible folder must complete")
        print("PASS empty folder")

        for path in ["hidden/.config", "hidden/.git/config", "hidden/normal", "hidden/.ordinary/file"] {
            try f.file(path)
        }
        for path in ["hidden/.DS_Store", "hidden/._sidecar", "hidden/.metadata_never_index", "hidden/.VolumeIcon.icns"] {
            try f.file(path)
        }
        let hidden = try await pin(f, ["hidden"])
        try require(hidden.filesRead == 4 && hidden.bytesRead == 148 && hidden.failedFiles == 0,
                    "Include ordinary hidden files, exclude known Apple metadata only")
        print("PASS hidden files and metadata exclusions")

        try f.file("overlap/sub/a", size: 123)
        try f.file("overlap/b", size: 456)
        let overlap = try await pin(f, ["overlap/sub", "overlap", "overlap/sub/a", "overlap"])
        try require(overlap.filesRead == 2 && overlap.bytesRead == 579
                    && overlap.pinnedPaths == ["overlap", "overlap/sub", "overlap/sub/a"],
                    "Read each overlapping selected file once; retain successful requested markers")
        print("PASS overlapping selections and duplicates")

        let external = try f.file("outside/secret", size: 300)
        _ = try f.directory("links")
        try f.file("links/regular")
        try FileManager.default.createSymbolicLink(at: f.base.appendingPathComponent("links/file-link"),
                                                  withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: f.base.appendingPathComponent("links/dir-link"),
                                                  withDestinationURL: external.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: f.base.appendingPathComponent("links/inside-link"),
                                                  withDestinationURL: f.base.appendingPathComponent("links/regular"))
        let links = try await pin(f, ["links"])
        try require(links.filesRead == 1 && links.bytesRead == 37 && links.failedFiles == 0,
                    "Do not traverse/read symlink descendants")
        let linkRoots = try await pin(f, ["links/file-link", "links/dir-link/secret", "links/inside-link"])
        try require(linkRoots.filesRead == 0 && linkRoots.failedFiles == 3 && linkRoots.pinnedPaths.isEmpty,
                    "Reject symlink roots and symlink intermediate components")
        print("PASS symlink descendants, roots, intermediate components")

        let badPaths = try await PinEngine.pin(roots: [external], mountPath: f.base.appendingPathComponent("links").path,
                                               relativePaths: ["../outside/secret"], progress: { _ in })
        let mismatch = try await PinEngine.pin(roots: [external], mountPath: f.base.path,
                                               relativePaths: ["fabricated-marker"], progress: { _ in })
        try require(badPaths.failedFiles == 1 && badPaths.pinnedPaths.isEmpty
                    && mismatch.failedFiles == 1 && mismatch.pinnedPaths.isEmpty,
                    "Reject outside roots and mismatched marker mapping")
        print("PASS containment and marker validation")

        try f.file("partial/good", size: 10)
        try f.file("partial/bad", size: 20)
        try f.file("independent/file", size: 30)
        let partial = try await pin(f, ["partial", "partial/good", "independent"],
                                    hooks: PinIOHooks(failRead: { $0 == "partial/bad" }))
        try require(partial.filesRead == 2 && partial.failedFiles == 1
                    && partial.pinnedPaths == ["partial/good", "independent"],
                    "Read failure must not mark a partially read ancestor complete")
        print("PASS injected read failure and partial-root markers")

        try f.file("enumeration/inaccessible/file")
        try f.file("enumeration/healthy/file")
        let enumeration = try await pin(f, ["enumeration", "enumeration/inaccessible", "enumeration/healthy"],
                                        hooks: PinIOHooks(failEnumeration: { $0 == "enumeration/inaccessible" }))
        try require(enumeration.failedFiles == 1 && enumeration.filesRead == 1
                    && enumeration.pinnedPaths == ["enumeration/healthy"],
                    "Enumeration errors invalidate affected roots, not healthy siblings")
        let missing = try await pin(f, ["not-present"])
        try require(missing.failedFiles == 1 && missing.pinnedPaths.isEmpty, "Missing root must fail")
        print("PASS injected enumeration failure and missing root")

        // Real POSIX errors on a deterministic fixture, with permissions restored
        // before guarded cleanup; injection above also covers elevated-user runs.
        let denied = try f.file("permissions/denied")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        let deniedResult = try await pin(f, ["permissions"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path)
        if geteuid() != 0 {
            try require(deniedResult.failedFiles == 1 && deniedResult.pinnedPaths.isEmpty,
                        "Actual unreadable file must fail")
            print("PASS real POSIX read-open failure")
        } else {
            print("SKIP root bypasses POSIX permissions; injected failure test passed")
        }
        let deniedDir = try f.directory("permissions-directory/denied")
        try f.file("permissions-directory/denied/file")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: deniedDir.path)
        let deniedDirectory = try await pin(f, ["permissions-directory"])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedDir.path)
        if geteuid() != 0 {
            try require(deniedDirectory.failedFiles >= 1 && deniedDirectory.pinnedPaths.isEmpty,
                        "Actual unreadable directory must fail")
            print("PASS real POSIX directory-open failure")
        }

        let truncation = try f.file("truncate/file", size: 1024)
        let mutated = OSAllocatedUnfairLock(initialState: false)
        let truncated = try await pin(f, ["truncate"], hooks: PinIOHooks(beforeRead: { _ in
            let first = mutated.withLock { state in
                if state { return false }
                state = true
                return true
            }
            if first { try? Data().write(to: truncation) }
        }))
        try require(truncated.filesRead == 0 && truncated.failedFiles == 1 && truncated.pinnedPaths.isEmpty,
                    "File truncation during warming must not be marked complete")
        print("PASS mutation/short-read validation")

        let before = Observations()
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pin(f, ["hidden"], hooks: before.hooks(), progress: before.record)
        }
        do {
            _ = try await preCancelled.value
            throw PinTestFailure(description: "Pre-cancelled pin must throw")
        } catch is CancellationError {}
        try require(before.state.maximumDescriptors == 0 && before.state.snapshots.isEmpty,
                    "Pre-start cancellation must do no filesystem work/callbacks")
        print("PASS pre-start cancellation")

        for index in 0..<32 { try f.file("cancel/\(index)", size: 16384) }
        let observed = Observations()
        let signal = ReadSignal()
        var cancellationHooks = observed.hooks()
        cancellationHooks.beforeRead = { _ in signal.fire(); usleep(30_000) }
        let frozenHooks = cancellationHooks
        let cancelling = Task {
            try await pin(f, ["cancel"], hooks: frozenHooks, progress: observed.record)
        }
        await signal.wait()
        cancelling.cancel()
        do {
            _ = try await cancelling.value
            throw PinTestFailure(description: "During-read cancellation must throw")
        } catch is CancellationError {}
        let after = observed.state
        try require(after.readers == 0 && after.descriptors == 0, "Cancellation must join workers and close all handles")
        try await Task.sleep(for: .milliseconds(60))
        try require(observed.state.readers == 0 && observed.state.descriptors == 0
                    && observed.state.snapshots.count == after.snapshots.count,
                    "No orphan work/progress after caller returns")
        print("PASS during-read cancellation, joined workers, descriptor cleanup")

        let enumerationObserved = Observations()
        let enumerationSignal = ReadSignal()
        var enumerationHooks = enumerationObserved.hooks()
        enumerationHooks.failEnumeration = { _ in
            enumerationSignal.fire()
            usleep(30_000)
            return false
        }
        let frozenEnumerationHooks = enumerationHooks
        let cancelEnumeration = Task {
            try await pin(f, ["cancel"], hooks: frozenEnumerationHooks, progress: enumerationObserved.record)
        }
        await enumerationSignal.wait()
        cancelEnumeration.cancel()
        do {
            _ = try await cancelEnumeration.value
            throw PinTestFailure(description: "During-enumeration cancellation must throw")
        } catch is CancellationError {}
        try require(enumerationObserved.state.descriptors == 0 && enumerationObserved.state.readers == 0,
                    "Cancellation must close an unfinished directory traversal")
        print("PASS during-enumeration cancellation and directory cleanup")

        for index in 0..<80 { try f.file("bounded/deep/sub/\(index)", size: 128) }
        for (requested, expected) in [(0, 1), (2, 2), (3, 3), (99, 4)] {
            let observation = Observations()
            let result = try await pin(f, ["bounded"], concurrency: requested,
                                       hooks: observation.hooks(delay: 3_000), progress: observation.record)
            let state = observation.state
            try require(result.filesRead == 80 && result.bytesRead == 10_240 && result.failedFiles == 0,
                        "Bounded reader totals")
            try require(state.maximumReaders == expected && state.readers == 0 && state.descriptors == 0,
                        "Reader concurrency must honor cap and close resources")
            try require(state.maximumDescriptors <= expected + 7, "Open handles bounded by readers + traversal depth")
            try require(state.snapshots.count <= Int(ceil(result.duration * 5)) + 2,
                        "Progress count must be bounded, not per file")
            if state.times.count > 3 {
                for index in 1..<(state.times.count - 1) {
                    try require(state.times[index] - state.times[index - 1] >= 200_000_000,
                                "Periodic snapshots must be separated by 200ms")
                }
            }
            try require(state.snapshots.last?.completedFiles == 80
                        && state.snapshots.last?.completedBytes == 10_240
                        && state.snapshots.last?.phase == .finishing, "Final progress totals")
        }
        print("PASS concurrency caps 1/2/3/4, progress bounds, resource bounds")

        try f.file("large/file", size: 9 * 1024 * 1024 + 13)
        let large = try await pin(f, ["large"])
        try require(large.filesRead == 1 && large.bytesRead == 9 * 1024 * 1024 + 13
                    && large.failedFiles == 0, "Multiple chunks and final short read preserve bytes")
        print("PASS multi-chunk read and short final chunk")
        print("All offline PinEngine tests passed.")
    }
}
