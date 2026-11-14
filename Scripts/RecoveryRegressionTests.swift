// Compiled after the private fixture prefix from MountLifecycleTests.swift by
// run-recovery-tests.sh. Production Models/Services/Views/App are all real Swift
// inputs. No State shim, app singleton, Keychain, Google, or actual mount is used.
import Darwin
import Foundation

private extension LifecycleEnvironment {
    static func recoveryHelper(python: String) -> String { helper(python: python) }
}

private actor RecoveryMountInspector: MountInspecting {
    private let pidFile: URL
    private var lastPID: Int32?
    private var attached = false
    private var normalAllowed = true
    private var forceGate: CheckedContinuation<Void, Never>?
    private var holdForce = false
    private(set) var forceBlocked = false
    private(set) var normalCalls = 0
    private(set) var forceCalls = 0

    init(pidFile: URL) { self.pidFile = pidFile }

    func isActive(path: String) async -> Bool {
        if let data = try? Data(contentsOf: pidFile),
           let pid = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
           pid != lastPID {
            lastPID = pid
            attached = true
        }
        return attached
    }

    func unmountIfUnused(path: String) async -> Bool {
        normalCalls += 1
        if normalAllowed { attached = false }
        return normalAllowed
    }

    func forceUnmount(path: String) async -> Bool {
        forceCalls += 1
        if holdForce {
            forceBlocked = true
            await withCheckedContinuation { forceGate = $0 }
            forceBlocked = false
        }
        attached = false
        return true
    }

    func allowNormal(_ allowed: Bool) { normalAllowed = allowed }
    func holdNextForce() { holdForce = true }
    func releaseForce() {
        holdForce = false
        let continuation = forceGate
        forceGate = nil
        continuation?.resume()
    }
}

/// Continuations deliberately ignore cancellation until explicitly released:
/// this models an old transport completing after process exit without unchecked
/// Sendable or thread-shared mutable state.
private actor RecoveryWriteReader: WriteSafetyReading {
    private var state: UploadSafetySnapshot.State
    private var heldState: UploadSafetySnapshot.State?
    private var gates: [Int: CheckedContinuation<UploadSafetySnapshot, Never>] = [:]
    private(set) var calls = 0
    private(set) var heldCalls: Set<Int> = []

    init(state: UploadSafetySnapshot.State = .idleObserved) { self.state = state }

    func read(client: RcloneRCClient, remote: String) async throws -> UploadSafetySnapshot {
        calls += 1
        let ordinal = calls
        if let heldState {
            self.heldState = nil
            heldCalls.insert(ordinal)
            return await withCheckedContinuation { gates[ordinal] = $0 }
                .replacingState(heldState)
        }
        return Self.snapshot(state)
    }

    func setState(_ state: UploadSafetySnapshot.State) { self.state = state }
    func holdNext(_ state: UploadSafetySnapshot.State) { heldState = state }
    func release(_ ordinal: Int) {
        let continuation = gates.removeValue(forKey: ordinal)
        heldCalls.remove(ordinal)
        continuation?.resume(returning: Self.snapshot(state))
    }
    func releaseAll() {
        heldState = nil
        let continuations = Array(gates.values)
        gates.removeAll()
        heldCalls.removeAll()
        for continuation in continuations { continuation.resume(returning: Self.snapshot(state)) }
    }

    private static func snapshot(_ state: UploadSafetySnapshot.State) -> UploadSafetySnapshot {
        UploadSafetySnapshot(state: state, checkedAt: Date(), pendingFiles: state == .idleObserved ? 0 : 2,
                             pendingBytes: state == .idleObserved ? 0 : 2048,
                             detail: "Private recovery fixture: \(state.rawValue)")
    }
}

private extension UploadSafetySnapshot {
    func replacingState(_ state: State) -> Self {
        var result = self
        result.state = state
        result.pendingFiles = state == .idleObserved ? 0 : 2
        result.pendingBytes = state == .idleObserved ? 0 : 2048
        result.detail = "Private recovery fixture: \(state.rawValue)"
        return result
    }
}

@MainActor
private final class RecoveryEnvironment {
    let directory: URL
    let paths: DriveStreamPaths
    let defaults: UserDefaults
    let suiteName: String
    let inspector: RecoveryMountInspector
    let reader: RecoveryWriteReader?
    let controller: MountController
    private let eventFile: URL

    init(root: URL, python: String, name: String,
         reader: RecoveryWriteReader? = RecoveryWriteReader(),
         initialRisk: UploadSafetySnapshot? = nil, blockLedger: Bool = false) throws {
        directory = root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        paths = DriveStreamPaths(applicationSupportDirectory: directory.appendingPathComponent("support"),
                                 homeDirectory: directory.appendingPathComponent("home"))
        try paths.prepareFileSystem()
        try Data(LifecycleEnvironment.recoveryHelper(python: python).utf8).write(to: paths.rcloneBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.rcloneBinary.path)
        try JSONEncoder().encode(HelperBehavior()).write(to: paths.applicationSupportDirectory.appendingPathComponent("behavior.json"))
        // The profile hook accepts this tokenless private fixture. No fake token
        // can accidentally reach a Google client, and the Keychain service is unused.
        try Data("[gdrive]\ntype = drive\n".utf8).write(to: paths.configFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configFile.path)
        eventFile = paths.applicationSupportDirectory.appendingPathComponent("events.jsonl")
        suiteName = "com.drivestream.recovery-tests.\(UUID().uuidString)"
        guard let privateDefaults = UserDefaults(suiteName: suiteName) else {
            throw LifecycleFailure(description: "Cannot create private recovery defaults")
        }
        defaults = privateDefaults
        var configuration = StreamConfig()
        configuration.volumeName = "Recovery Fixture"
        configuration.customMountPath = directory.appendingPathComponent("mount").path
        configuration.mountBackend = .nfs
        configuration.autoMountOnLaunch = false
        configuration.suppressSpotlightIndexing = false
        configuration.showDriveOnDesktop = false
        configuration.recoverMountAfterWake = true
        guard configuration.validationError == nil else {
            throw LifecycleFailure(description: "Private recovery mount path failed validation")
        }
        StreamConfigStore.save(configuration, to: defaults)
        if let initialRisk, !WriteRiskStore.record(initialRisk, paths: paths) {
            throw LifecycleFailure(description: "Could not seed private ledger")
        }
        if blockLedger {
            try FileManager.default.createDirectory(at: paths.applicationSupportDirectory.appendingPathComponent("pending-writes.json"),
                                                    withIntermediateDirectories: false)
        }
        let keychain = KeychainHelper(service: "com.drivestream.unused-recovery.\(UUID().uuidString)")
        inspector = RecoveryMountInspector(pidFile: paths.applicationSupportDirectory.appendingPathComponent("mount.pid"))
        self.reader = reader
        controller = MountController(dependencyManager: DependencyManager(paths: paths),
                                     configService: RcloneConfigService(paths: paths, keychain: keychain),
                                     rcClient: RcloneRCClient(), paths: paths, keychain: keychain,
                                     configuration: configuration, initialPins: [], mountInspector: inspector,
                                     defaults: defaults, enableFinderIntegration: false, backendCandidates: [.nfs],
                                     writeSafetyReader: reader, profileIsUsable: { $0?.type == "drive" })
    }

    var metadata: URL { paths.cacheDirectory.appendingPathComponent("vfsMeta", isDirectory: true) }
    var ledger: URL { paths.applicationSupportDirectory.appendingPathComponent("pending-writes.json") }

    func events() -> [HelperEvent] {
        guard let data = try? Data(contentsOf: eventFile) else { return [] }
        return data.split(separator: 10).compactMap { try? JSONDecoder().decode(HelperEvent.self, from: Data($0)) }
    }
    func count(_ kind: String) -> Int { events().filter { $0.kind == kind }.count }
    func pid() -> Int32? { events().last(where: { $0.kind == "nfsmount" })?.pid }

    func stopOwnedHelper() async throws {
        guard let pid = pid(), pid > 1, controller.rcloneProcessIsActive,
              try await controller.rcClient.processID() == Int(pid) else {
            throw LifecycleFailure(description: "Refusing to signal an unverified fixture PID")
        }
        guard kill(pid, SIGTERM) == 0 else { throw LifecycleFailure(description: "Could not stop own fixture helper") }
    }

    /// Check both lexical and canonical ownership immediately before deletion.
    func removePrivate(_ url: URL) throws {
        let path = url.standardizedFileURL
        let root = directory.standardizedFileURL
        let canonicalRoot = root.resolvingSymlinksInPath()
        guard path.path.hasPrefix(root.path + "/"),
              path.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot.path + "/"),
              path.resolvingSymlinksInPath() == canonicalRoot.appendingPathComponent(String(path.path.dropFirst(root.path.count + 1))) else {
            throw LifecycleFailure(description: "Refusing unexpected private cleanup target")
        }
        try FileManager.default.removeItem(at: path)
    }

    func close() async {
        await reader?.releaseAll()
        await inspector.releaseForce()
        await inspector.allowNormal(true)
        _ = await controller.shutdownForTermination(allowPendingUploads: true)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@main
@MainActor
struct RecoveryRegressionTests {
    private static var checks = 0
    private static var environments: [RecoveryEnvironment] = []
    private static var root = URL(fileURLWithPath: "/tmp", isDirectory: true)
    private static var python = ""

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw LifecycleFailure(description: message) }
        checks += 1
        print("ok - \(message)")
    }

    private static func waitUntil(_ message: String, timeout: Duration = .seconds(6),
                                  condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LifecycleFailure(description: "Timed out: \(message)")
    }

    private static func make(_ name: String, reader: RecoveryWriteReader? = RecoveryWriteReader(),
                             initialRisk: UploadSafetySnapshot? = nil, blockLedger: Bool = false) throws -> RecoveryEnvironment {
        let environment = try RecoveryEnvironment(root: root, python: python, name: name, reader: reader,
                                                  initialRisk: initialRisk, blockLedger: blockLedger)
        environments.append(environment)
        return environment
    }

    private static func mountAndPause(_ env: RecoveryEnvironment) async throws {
        let mounted = await env.controller.mount()
        try expect(mounted, "\(env.directory.lastPathComponent.split(separator: "-").first ?? "fixture") starts an authenticated private helper")
        if let reader = env.reader {
            // Drain the initial actor read before installing a held fresh-read
            // plan. Scheduler yields alone are not a completion barrier.
            try await waitUntil("initial private reader has completed") { await reader.calls > 0 }
        }
        env.controller.handleDeviceLifecycle(.willSleep)
    }

    private static func freshnessTests() throws {
        let fresh = UploadSafetySnapshot(state: .idleObserved, checkedAt: Date(), pendingFiles: 0)
        let future = UploadSafetySnapshot(state: .idleObserved, checkedAt: Date().addingTimeInterval(60))
        let stale = UploadSafetySnapshot(state: .idleObserved, checkedAt: Date().addingTimeInterval(-60))
        try expect(fresh.isFresh && !fresh.requiresExitConsent, "a current idle observation is fresh, not a durable cloud guarantee")
        try expect(!future.isFresh && future.requiresExitConsent, "future-dated idle fails closed")
        try expect(!stale.isFresh && stale.requiresExitConsent, "stale idle fails closed")
        try expect(!UploadSafetySnapshot().isFresh, "an unchecked UI snapshot is never fresh")
        let vfs = try JSONDecoder().decode(RcloneVFSStats.self, from: Data(#"{"inUse":42,"diskCache":{"uploadsQueued":0,"uploadsInProgress":0,"erroredFiles":0,"outOfSpace":false}}"#.utf8))
        var core = RcloneCoreStats()
        core.fatalError = false
        let safety = UploadSafetySnapshot.assess(queue: RcloneUploadQueue(), vfs: vfs, core: core)
        try expect(safety.state == .idleObserved, "vfs.inUse is not inferred to be an open-writer count")
    }

    private static func sourceSafetyGateTests() throws {
        // A .failed state retaining a running process is reachable only through
        // bounded abort/escalation failure, not safely induced on a fast fixture.
        // Check the actual compiled source snapshot rather than introducing a
        // private state-mutation hook or replacing production MountState.
        let source = try String(contentsOf: root.appendingPathComponent("build/Sources/Services/MountController.swift"), encoding: .utf8)
        guard let function = source.range(of: "private func performUnmount(allowPendingUploads: Bool)"),
              let gate = source.range(of: "if !allowPendingUploads,", range: function.upperBound..<source.endIndex),
              let body = source[gate.lowerBound...].firstIndex(of: "{") else {
            throw LifecycleFailure(description: "Could not locate compiled live-helper unmount safety gate")
        }
        let conditions = String(source[gate.lowerBound..<body])
        try expect(conditions.contains("ownsCurrentMount") && conditions.contains("process?.isRunning == true")
                   && !conditions.contains("isMounted") && !conditions.contains("state.status") && !conditions.contains("rcClient.baseURL"),
                   "compiled fresh-write guard covers owned running helper even in failed state or without endpoint")
        let delegate = try String(contentsOf: root.appendingPathComponent("build/Sources/App/AppDelegate.swift"), encoding: .utf8)
        try expect(delegate.contains("guard controller.needsExitAssessment else"),
                   "compiled AppDelegate quit fast path consults the persisted-risk safety proof")
    }

    private static func singleflightTests() async throws {
        let reader = RecoveryWriteReader()
        let env = try make("singleflight", reader: reader)
        try await mountAndPause(env)
        await reader.holdNext(.pending)
        let first = Task { await env.controller.refreshWriteSafetyNow() }
        try await waitUntil("first fresh reader is held") { !(await reader.heldCalls).isEmpty }
        guard let ordinal = await reader.heldCalls.first else { throw LifecycleFailure(description: "Missing reader gate") }
        let calls = await reader.calls
        var secondEntered = false
        let second = Task {
            secondEntered = true
            return await env.controller.refreshWriteSafetyNow()
        }
        try await waitUntil("second UI request entered") { secondEntered }
        for _ in 0..<4 { await Task.yield() }
        let coalescedCalls = await reader.calls
        try expect(coalescedCalls == calls && env.controller.isCheckingWrites, "two delayed UI checks coalesce into one fresh reader operation")
        await reader.release(ordinal)
        let one = await first.value
        let two = await second.value
        try expect(one == two && one.state == .pending && one.requiresExitConsent, "both coalesced requests receive pending rather than cached idle")
        try expect(!env.controller.isCheckingWrites && env.controller.uploadSafety.state == .pending, "singleflight completion publishes pending and clears only its own busy flag")
        let persisted = WriteRiskStore.load(paths: env.paths)
        try expect(persisted?.state == .pending, "fresh pending evidence is persisted in the isolated ledger")
        await reader.setState(.idleObserved)
        let idle = await env.controller.refreshWriteSafetyNow()
        try expect(idle.state == .idleObserved, "a subsequent fresh operation is not stuck on the completed singleflight task")
        env.controller.rcClient.clearCredentials()
        let absent = await env.controller.refreshWriteSafetyNow()
        try expect(absent.state == .unknown && absent.requiresExitConsent, "an absent endpoint never returns cached idle as exit authorization")
        await env.controller.unmount()
        try expect(env.controller.hasMountSession && env.controller.exitBlockedByWrites, "normal unmount with a live helper but absent endpoint refuses unknown writes")
        await env.close()
    }

    private static func staleResponseTests() async throws {
        let reader = RecoveryWriteReader()
        let env = try make("oldresponse", reader: reader)
        try await mountAndPause(env)
        await reader.holdNext(.idleObserved)
        let old = Task { await env.controller.refreshWriteSafetyNow() }
        try await waitUntil("old response is held") { !(await reader.heldCalls).isEmpty }
        guard let oldOrdinal = await reader.heldCalls.first else { throw LifecycleFailure(description: "Missing old gate") }
        try await env.stopOwnedHelper()
        try await waitUntil("old helper cleanup completes") { !env.controller.hasMountSession && !env.controller.isBusy }
        await reader.setState(.pending)
        env.controller.handleDeviceLifecycle(.didWake)
        try await waitUntil("replacement mount and wake owner settle") { env.count("nfsmount") == 2 && env.controller.isMounted && !env.controller.isBusy }
        env.controller.handleDeviceLifecycle(.willSleep)
        let baseline = await env.controller.refreshWriteSafetyNow()
        try expect(baseline.state == .pending, "replacement pending baseline is freshly read after ordinary telemetry is paused")
        await reader.holdNext(.pending)
        let current = Task { await env.controller.refreshWriteSafetyNow() }
        try await waitUntil("replacement response is held") { (await reader.heldCalls).count == 2 }
        guard let newOrdinal = await reader.heldCalls.first(where: { $0 != oldOrdinal }) else {
            throw LifecycleFailure(description: "Missing replacement gate")
        }
        await reader.release(oldOrdinal)
        let stale = await old.value
        try expect(stale.state == .unknown && stale.requiresExitConsent, "a cancelled old-helper response cannot authorize exit")
        try expect(env.controller.uploadSafety.state == .pending && env.controller.isCheckingWrites, "old response cannot overwrite current pending or clear the new request owner")
        await reader.release(newOrdinal)
        let replacement = await current.value
        try expect(replacement.state == .pending && !env.controller.isCheckingWrites, "the replacement generation publishes and clears its own write-check owner")
        try expect(WriteRiskStore.load(paths: env.paths)?.state == .pending, "late old idle cannot clear replacement pending ledger")
        await env.close()
    }

    private static func dirtyCacheTests() async throws {
        let env = try make("dirtycache", reader: nil)
        try FileManager.default.createDirectory(at: env.metadata, withIntermediateDirectories: true)
        let dirty = env.metadata.appendingPathComponent("dirty.json")
        let clean = env.metadata.appendingPathComponent("clean.json")
        let dirtyData = Data(#"{"Dirty":true,"Size":17,"ModTime":"2026-01-01T00:00:00Z"}"#.utf8)
        let cleanData = Data(#"{"Dirty":false}"#.utf8)
        try dirtyData.write(to: dirty)
        try cleanData.write(to: clean)
        let before = try dirty.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let scanned = await DirtyCacheInspection.inspect(metadataPath: env.metadata.path, cacheRoot: env.paths.cacheDirectory)
        try expect(scanned.complete && scanned.dirtyFiles == 1, "local trueDirty and falseDirty metadata are read independently")
        let cleanOnly = env.paths.cacheDirectory.appendingPathComponent("clean-only", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanOnly, withIntermediateDirectories: false)
        try cleanData.write(to: cleanOnly.appendingPathComponent("clean.json"))
        let cleanScan = await DirtyCacheInspection.inspect(metadataPath: cleanOnly.path, cacheRoot: env.paths.cacheDirectory)
        try expect(cleanScan.complete && cleanScan.dirtyFiles == 0, "a complete falseDirty-only inventory is observed clean")
        let oversizedMeta = env.paths.cacheDirectory.appendingPathComponent("oversized-metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: oversizedMeta, withIntermediateDirectories: false)
        var paddedMetadata = cleanData
        paddedMetadata.append(Data(repeating: 32, count: 256 * 1024 + 1 - paddedMetadata.count))
        try paddedMetadata.write(to: oversizedMeta.appendingPathComponent("oversized.json"))
        let boundedScan = await DirtyCacheInspection.inspect(metadataPath: oversizedMeta.path, cacheRoot: env.paths.cacheDirectory)
        try expect(!boundedScan.complete, "oversized valid metadata is bounded and fails closed")
        let afterData = try Data(contentsOf: dirty)
        let after = try dirty.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try expect(afterData == dirtyData && before == after, "dirty metadata inspection is read-only")
        try await mountAndPause(env)
        let fresh = await env.controller.refreshWriteSafetyNow()
        try expect(fresh.state == .pending && fresh.pendingFiles == 1 && fresh.requiresExitConsent, "empty RC queue plus dirty local metadata still requires consent")
        let pid = env.pid()
        await env.controller.unmount()
        try expect(env.controller.exitBlockedByWrites && env.controller.rcloneProcessIsActive && env.pid() == pid, "dirty metadata refuses normal unmount without stopping its helper")
        let retainedData = try Data(contentsOf: dirty)
        try expect(retainedData == dirtyData, "refused dirty-cache unmount leaves private cache bytes intact")
        let explicit = await env.controller.shutdownForTermination(allowPendingUploads: true)
        try expect(explicit && !env.controller.hasMountSession, "explicit Quit Anyway detaches the owned volume")
        let explicitData = try Data(contentsOf: dirty)
        try expect(explicitData == dirtyData && WriteRiskStore.load(paths: env.paths)?.state == .pending, "explicit Quit Anyway retains dirty cache and persisted warning")
        let normalCalls = await env.inspector.normalCalls
        let forceCalls = await env.inspector.forceCalls
        try expect(normalCalls == 0 && forceCalls == 1, "explicit interrupted exit uses detach-only, not a writer-safe normal-unmount claim")

        let malformed = env.metadata.appendingPathComponent("malformed.json")
        try Data(#"{"Dirty":"true"}"#.utf8).write(to: malformed)
        let bad = await DirtyCacheInspection.inspect(metadataPath: env.metadata.path, cacheRoot: env.paths.cacheDirectory)
        try expect(!bad.complete, "malformed Dirty metadata fails closed")
        try env.removePrivate(malformed)
        let external = env.directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try Data(#"{"Dirty":false}"#.utf8).write(to: external.appendingPathComponent("clean.json"))
        let escaped = env.paths.cacheDirectory.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: external)
        let escape = await DirtyCacheInspection.inspect(metadataPath: escaped.path, cacheRoot: env.paths.cacheDirectory)
        try expect(!escape.complete, "symlink metadata directory escaping the cache fails closed")
        let linkedFile = env.metadata.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: external.appendingPathComponent("clean.json"))
        let nestedEscape = await DirtyCacheInspection.inspect(metadataPath: env.metadata.path, cacheRoot: env.paths.cacheDirectory)
        try expect(!nestedEscape.complete, "a symlink entry inside metadata cannot masquerade as clean")
        let missing = await DirtyCacheInspection.inspect(metadataPath: nil, cacheRoot: env.paths.cacheDirectory)
        try expect(!missing.complete, "missing metadata path never proves a clean cache")
        await env.close()
    }

    private static func busyUnmountTests() async throws {
        let env = try make("busywriter")
        try await mountAndPause(env)
        await env.inspector.allowNormal(false)
        let pid = env.pid()
        await env.controller.unmount()
        let normal = await env.inspector.normalCalls
        let force = await env.inspector.forceCalls
        try expect(normal == 1 && force == 0, "busy/open-file inspector refuses normal unmount without force fallback")
        try expect(env.controller.hasMountSession && env.controller.rcloneProcessIsActive && env.pid() == pid, "busy normal-unmount refusal does not kill the owned helper")
        if let pid { try expect(kill(pid, 0) == 0, "the same private helper remains alive after busy refusal") }
        else { throw LifecycleFailure(description: "Missing busy fixture PID") }
        try expect(env.controller.mountIssue?.title == "Files are still open on this volume" && !env.controller.exitBlockedByWrites,
                   "writer-open refusal is distinct from cloud-queue consent")
        await env.inspector.allowNormal(true)
        await env.controller.unmount()
        try expect(!env.controller.hasMountSession, "closing writers permits a later fresh normal unmount")
        await env.close()
    }

    private static func persistedQuitTests() async throws {
        let risk = UploadSafetySnapshot(state: .pending, checkedAt: Date().addingTimeInterval(-3600), pendingFiles: 3,
                                        pendingBytes: 123, detail: "Private interrupted-write recovery")
        let env = try make("persistedquit", initialRisk: risk)
        try expect(!env.controller.hasMountSession && env.controller.uploadSafety.state == .pending, "restarted controller loads pending ledger without a helper")
        try expect(env.controller.needsExitAssessment, "persisted pending routes the no-helper AppDelegate fast path through exit assessment")
        let refused = await env.controller.shutdownForTermination()
        try expect(!refused && env.controller.exitBlockedByWrites && !env.controller.isBusy, "persisted pending without helper requires explicit quit consent and leaves retry controls available")
        try expect(env.count("nfsmount") == 0 && env.count("authorize") == 0 && env.count("config") == 0, "persisted-risk quit invokes no mount or authorization helper")
        let explicit = await env.controller.shutdownForTermination(allowPendingUploads: true)
        try expect(explicit && WriteRiskStore.load(paths: env.paths) == risk, "explicit no-helper Quit Anyway retains the exact pending warning")
        await env.close()
    }

    private static func ledgerTests() async throws {
        let reader = RecoveryWriteReader(state: .pending)
        let env = try make("ledgerretry", reader: reader, blockLedger: true)
        try await mountAndPause(env)
        let pending = await env.controller.refreshWriteSafetyNow()
        try expect(pending.state == .pending && WriteRiskStore.load(paths: env.paths) == nil,
                   "injected destination-directory failure cannot claim the pending ledger was persisted")
        try env.removePrivate(env.ledger)
        // Controller intentionally backs off failed persistence for five seconds.
        // Retry identical evidence after that bound, not a changed state/timestamp.
        try await Task.sleep(for: .milliseconds(5100))
        let retry = await env.controller.refreshWriteSafetyNow()
        try expect(retry.state == .pending && WriteRiskStore.load(paths: env.paths)?.state == .pending,
                   "the same pending evidence persists on retry after the first ledger write failed")
        var bytes = try JSONEncoder().encode(retry)
        bytes.append(Data(repeating: 32, count: 64 * 1024 + 1 - bytes.count))
        try bytes.write(to: env.ledger)
        let start = ContinuousClock.now
        let oversized = WriteRiskStore.load(paths: env.paths)
        try expect(oversized == nil && ContinuousClock.now - start < .seconds(2), "valid JSON with oversized padding is bounded and rejected by the ledger reader")
        await env.close()
    }

    private static func wakeOwnershipTests() async throws {
        let env = try make("wakeowner")
        try await mountAndPause(env)
        await env.inspector.holdNextForce()
        try await env.stopOwnedHelper()
        try await waitUntil("crash cleanup is held") { await env.inspector.forceBlocked }
        env.controller.handleDeviceLifecycle(.didWake) // wake A awaits joined cleanup
        for _ in 0..<4 { await Task.yield() }
        env.controller.handleDeviceLifecycle(.willSleep) // sleep B cancels A
        env.controller.handleDeviceLifecycle(.didWake) // wake B records new intent
        await env.inspector.releaseForce()
        try await waitUntil("wake B remounts after old task returns") { env.count("nfsmount") == 2 && env.controller.isMounted && !env.controller.isBusy }
        try expect(!env.controller.isSleeping && env.count("nfsmount") == 2, "wake A held then sleep B/wake B cannot let old task clear the new recovery intent")
        await env.controller.unmount()
        let before = env.count("nfsmount")
        env.controller.handleDeviceLifecycle(.network(.unavailable))
        env.controller.handleDeviceLifecycle(.network(.available))
        for _ in 0..<8 { await Task.yield() }
        try expect(!env.controller.hasMountSession && env.count("nfsmount") == before && !env.controller.isBusy,
                   "explicit unmount clears wake intent so later network availability cannot remount")
        await env.close()
    }

    private static func failedWakeTests() async throws {
        let env = try make("failedwake")
        try await mountAndPause(env)
        try await env.stopOwnedHelper()
        try await waitUntil("failed wake fixture crash cleans attachment") { !env.controller.hasMountSession && !env.controller.isBusy }
        let blocker = URL(fileURLWithPath: env.controller.mountPath, isDirectory: true).appendingPathComponent("intentional-blocker")
        try Data("private mount-readiness failure".utf8).write(to: blocker)
        env.controller.handleDeviceLifecycle(.didWake)
        try await waitUntil("first wake recovery fails") { env.controller.state.status == .failed && !env.controller.isBusy }
        try expect(env.count("nfsmount") == 1 && !env.controller.hasMountSession, "failed recovery never launches a replacement into a nonempty private mount path")
        try env.removePrivate(blocker)
        env.controller.handleDeviceLifecycle(.network(.unavailable))
        env.controller.handleDeviceLifecycle(.network(.available))
        try await waitUntil("later network event retries preserved wake intent") { env.count("nfsmount") == 2 && env.controller.isMounted && !env.controller.isBusy }
        try expect(env.count("nfsmount") == 2, "failed wake recovery retains intent for a later available network")
        await env.close()
    }

    private static var failures: [String] = []

    private static func run(_ name: String, operation: @MainActor () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            failures.append("\(name): \(error)")
            FileHandle.standardError.write(Data("FAIL: \(name): \(error)\n".utf8))
            // Release adversarial held actors before continuing independent groups.
            for environment in environments { await environment.close() }
        }
    }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw LifecycleFailure(description: "usage: RecoveryRegressionTests <private-/tmp-root> <absolute-python>")
            }
            root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            python = CommandLine.arguments[2]
            guard root.path.hasPrefix("/tmp/drivestream-recovery."), python.hasPrefix("/"),
                  !python.contains("\n"), !python.contains(" ") else {
                throw LifecycleFailure(description: "Refusing unsafe recovery fixture paths")
            }
            await run("snapshot freshness") { try freshnessTests() }
            await run("compiled safety gates") { try sourceSafetyGateTests() }
            await run("fresh singleflight") { try await singleflightTests() }
            await run("old response ownership") { try await staleResponseTests() }
            await run("dirty cache consent") { try await dirtyCacheTests() }
            await run("busy normal unmount") { try await busyUnmountTests() }
            await run("persisted-risk quit") { try await persistedQuitTests() }
            await run("ledger failure retry") { try await ledgerTests() }
            await run("wake task ownership") { try await wakeOwnershipTests() }
            await run("failed wake recovery") { try await failedWakeTests() }
            for environment in environments { await environment.close() }
            guard failures.isEmpty else {
                throw LifecycleFailure(description: "\(failures.count) recovery groups failed after \(checks) passing checks: " + failures.joined(separator: "; "))
            }
            print("All \(checks) recovery regression checks passed (Swift 6, complete strict concurrency, real sources/SDK, isolated offline fixtures).")
        } catch {
            for environment in environments { await environment.close() }
            FileHandle.standardError.write(Data("FAIL: recovery regression: \(error)\n".utf8))
            exit(1)
        }
    }
}
