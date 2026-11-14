import AppKit
import Combine
import Darwin
import Foundation
import Security

// MARK: - MountController

@MainActor
final class MountController: ObservableObject {
    let dependencyManager: DependencyManager
    let configService: RcloneConfigService
    let rcClient: RcloneRCClient
    let paths: DriveStreamPaths

    private let keychain: KeychainHelper
    private let mountInspector: any MountInspecting
    private let defaults: UserDefaults
    private let enableFinderIntegration: Bool
    private let backendCandidates: [VolumeBackend]?
    private let writeSafetyReader: any WriteSafetyReading
    private let profileIsUsable: @Sendable (RcloneRemoteProfile?) -> Bool

    @Published private(set) var config: StreamConfig
    @Published private(set) var state: MountState
    @Published private(set) var telemetry = TelemetrySnapshot()
    @Published private(set) var isIndexing = false
    @Published private(set) var indexingStartedAt: Date?
    @Published private(set) var pinProgress: PinProgress?
    @Published private(set) var isConnecting = false
    @Published private(set) var connectionMessage: String?
    @Published private(set) var remoteIsConfigured: Bool
    @Published private(set) var accountLabel: String?
    @Published private(set) var accountGeneration = UUID()
    @Published private(set) var errorMessage: String? {
        didSet {
            if errorMessage != mountIssue?.summary { mountIssue = nil }
        }
    }
    @Published private(set) var mountIssue: DriveStreamIssue?
    @Published private(set) var telemetryWarning: String?
    @Published private(set) var quotaWarning: String?
    @Published private(set) var telemetryRetryInProgress = false
    @Published private(set) var telemetryIsStale = false
    @Published private(set) var toastMessage: String?
    @Published private(set) var refreshInProgress = false
    @Published private(set) var freeUpInProgress = false
    @Published private(set) var startupComplete = false
    @Published private(set) var pinnedPaths: Set<String>
    @Published private(set) var activeLogPath: String?
    @Published private(set) var uploadSafety = UploadSafetySnapshot()
    @Published private(set) var exitBlockedByWrites = false
    @Published private(set) var connectivity: ConnectivityState = .unknown
    @Published private(set) var isSleeping = false
    @Published private(set) var isCheckingWrites = false

    private var rcloneProcess: Process?
    private var mountTask: Task<Bool, Never>?
    private var unmountTask: Task<Void, Never>?
    private var recoveryCleanupTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Error>?
    private var configurationTask: Task<Void, Error>?
    private var terminationInProgress = false
    private var ownsCurrentMount = false
    private var activeLogURL: URL?
    private var activeBackend: VolumeBackend?
    private let telemetryCoordinator = MountTelemetryCoordinator()
    private var queueTask: Task<Void, Never>?
    private var queueRequestID: UUID?
    private var wakeRecoveryTask: Task<Void, Never>?
    private var wakeRequestID: UUID?
    private var lifecycleEpoch = 0
    private var wakeRecoveryRequested = false
    private var wasMountedBeforeSleep = false
    private var pinOperationID: UUID?
    private var lastPersistedWriteRisk: UploadSafetySnapshot?
    private var writeCheckTask: Task<UploadSafetySnapshot, Never>?
    private var writeCheckID: UUID?
    private var writeCheckGeneration = -1
    private var nextWriteRiskRetry = ContinuousClock.now
    private var indexingTask: Task<Void, Never>?
    private var pinTask: Task<PinResult, Error>?
    private var presentationTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var mountOperationInProgress = false
    private var isUnmounting = false
    private var didBootstrap = false
    private var processGeneration = 0
    private var indexingGeneration = 0
    private let rcUsername = RcloneRCClient.defaultUsername
    private var rcPassword = ""

    init(
        dependencyManager: DependencyManager,
        configService: RcloneConfigService,
        rcClient: RcloneRCClient,
        paths: DriveStreamPaths,
        keychain: KeychainHelper = .shared,
        configuration: StreamConfig? = nil,
        initialPins: Set<String>? = nil,
        mountInspector: any MountInspecting = SystemMountInspector(),
        defaults: UserDefaults = .standard,
        enableFinderIntegration: Bool = true,
        backendCandidates: [VolumeBackend]? = nil,
        writeSafetyReader: (any WriteSafetyReading)? = nil,
        profileIsUsable: (@Sendable (RcloneRemoteProfile?) -> Bool)? = nil
    ) {
        self.dependencyManager = dependencyManager
        self.configService = configService
        self.rcClient = rcClient
        self.paths = paths
        self.keychain = keychain
        self.mountInspector = mountInspector
        self.defaults = defaults
        self.enableFinderIntegration = enableFinderIntegration
        self.backendCandidates = backendCandidates
        self.writeSafetyReader = writeSafetyReader ?? RemoteWriteSafetyReader(cacheRoot: paths.cacheDirectory)
        self.profileIsUsable = profileIsUsable ?? Self.isDriveConfigured

        var loadedConfig = configuration ?? StreamConfigStore.load(from: defaults)
        let savedRootID = loadedConfig.sharedDriveID
        let profile = configService.profile(for: loadedConfig.remoteName)
        loadedConfig.sharedDriveID = profile?.sharedDriveID ?? ""
        self.config = loadedConfig
        self.pinnedPaths = savedRootID == loadedConfig.sharedDriveID ? (initialPins ?? PinnedPathStore.load(from: defaults)) : []
        self.remoteIsConfigured = (profileIsUsable ?? Self.isDriveConfigured)(profile)
        self.accountLabel = loadedConfig.accountEmail.isEmpty ? nil : loadedConfig.accountEmail
        var initialState = MountState()
        initialState.status = .unmounted
        initialState.volumeName = loadedConfig.sanitizedVolumeName
        initialState.mountPath = loadedConfig.resolvedMountPath(
            volumesWritable: FileManager.default.isWritableFile(atPath: "/Volumes")
        )
        self.state = initialState
        if savedRootID != loadedConfig.sharedDriveID { PinnedPathStore.save([], to: defaults) }
        if let risk = WriteRiskStore.load(paths: paths) {
            self.uploadSafety = risk
            self.lastPersistedWriteRisk = risk
        }

    }

    // MARK: Computed UI state

    var mountPath: String {
        state.mountPath.isEmpty
            ? config.resolvedMountPath(volumesWritable: FileManager.default.isWritableFile(atPath: "/Volumes"))
            : state.mountPath
    }

    var volumeName: String { config.sanitizedVolumeName }

    var isMounted: Bool { state.status.isMounted }

    var rcloneProcessIsActive: Bool { rcloneProcess != nil }

    var hasMountSession: Bool { isMounted || rcloneProcess != nil || state.volumeStillAttached }

    var needsExitAssessment: Bool {
        hasMountSession || isBusy || lastPersistedWriteRisk?.state == .pending
            || lastPersistedWriteRisk?.state == .blocked
    }

    var isBusy: Bool {
        state.status.isBusy || mountOperationInProgress || isConnecting || freeUpInProgress
            || connectionTask != nil || configurationTask != nil || recoveryCleanupTask != nil
            || unmountTask != nil || terminationInProgress || isCheckingWrites || wakeRecoveryTask != nil
    }

    var isGoogleConnected: Bool { remoteIsConfigured }

    var backendDescription: String {
        state.backend?.technicalSummary ?? config.mountBackend.summary
    }

    var statusTitle: String {
        if isSleeping { return "Sleeping · mount preserved" }
        if connectivity == .unavailable && isMounted { return "Offline · cached volume" }
        if uploadSafety.state == .blocked { return "Cloud writes need attention" }
        if isIndexing { return "Indexing directory tree" }
        return state.status.title
    }

    var menuBarSymbolName: String {
        if state.status == .failed { return "exclamationmark.triangle" }
        if isIndexing { return "arrow.triangle.2.circlepath" }
        if isMounted { return "externaldrive.fill" }
        return "externaldrive"
    }

    var cacheLimitBytes: Int64 { config.cacheCapBytes }

    var pinnedCount: Int { pinnedPaths.count }

    var hasStoredEncryptionPassword: Bool {
        keychain.containsValue(for: KeychainAccountName.cryptPassword)
    }

    var currentLogURL: URL? { activeLogURL ?? paths.latestLogFile() }

    var rcloneVersionText: String {
        guard let installation = dependencyManager.installation else { return "Not installed" }
        return installation.displayVersion
    }

    var mountDurationText: String {
        guard let seconds = state.mountedDuration, isMounted else { return "—" }
        return ByteFormat.duration(seconds)
    }

    // MARK: Bootstrapping

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        if enableFinderIntegration { await FinderIntegrationService.applyFirstRunSetupIfNeeded() }
        let ready = await dependencyManager.prepare()
        refreshConnectionState()

        if ready, remoteIsConfigured, config.autoMountOnLaunch {
            _ = await mount()
        } else if !ready {
            if let dependencyError = dependencyManager.lastError {
                errorMessage = dependencyError
            }
        }
        startupComplete = true
    }

    func refreshConnectionState() {
        if let profile = configService.profile(for: config.remoteName) {
            remoteIsConfigured = profileIsUsable(profile)
            let rootID = profile.sharedDriveID ?? ""
            if config.sharedDriveID != rootID {
                config.sharedDriveID = rootID
                pinnedPaths = []
                PinnedPathStore.save(pinnedPaths, to: defaults)
            }
        } else {
            remoteIsConfigured = false
        }
        accountLabel = config.accountEmail.isEmpty ? nil : config.accountEmail
    }

    nonisolated private static func isDriveConfigured(_ profile: RcloneRemoteProfile?) -> Bool {
        guard let profile else { return false }
        return profile.type == "drive" && profile.hasToken
    }

    // MARK: Mount / unmount

    @discardableResult
    func mount() async -> Bool {
        await mountVolume(allowOwnedConfigurationOperation: false)
    }

    private func mountVolume(allowOwnedConfigurationOperation: Bool) async -> Bool {
        guard !terminationInProgress, !isSleeping else { return false }
        if let cleanup = recoveryCleanupTask {
            await cleanup.value
        }
        guard !Task.isCancelled, !terminationInProgress else { return false }
        guard allowOwnedConfigurationOperation || (connectionTask == nil && configurationTask == nil) else {
            showToast("Finish the account or configuration change before mounting.")
            return false
        }
        guard !mountOperationInProgress else {
            showToast("A mount operation is already in progress.")
            return false
        }
        guard !isUnmounting else {
            showToast("Please wait for the previous unmount to finish.")
            return false
        }
        if isMounted { return true }

        guard rcloneProcess == nil, !state.volumeStillAttached else {
            errorMessage = "The previous mount is still attached. Retry unmounting it before starting another mount."
            return false
        }
        mountOperationInProgress = true
        let task = Task { await performMount() }
        mountTask = task
        defer {
            mountTask = nil
            mountOperationInProgress = false
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performMount() async -> Bool {
        let previousLogURL = activeLogURL
        errorMessage = nil
        mountIssue = nil
        state.lastError = nil
        refreshConnectionState()

        guard remoteIsConfigured else {
            state.status = .unmounted
            errorMessage = MountControllerError.googleAccountMissing.localizedDescription
            NotificationCenter.default.post(name: .driveStreamShowOnboarding, object: nil)
            return false
        }

        state.status = .preparing
        state.mountStartedAt = Date()
        state.mountedAt = nil
        state.backend = nil

        do {
            let dependencyReady = await dependencyManager.prepare()
            try Task.checkCancellation()
            guard dependencyReady else {
                throw MountControllerError.dependencyUnavailable(
                    dependencyManager.lastError ?? "rclone is not available."
                )
            }
            if let validationError = config.validationError {
                throw MountControllerError.invalidConfiguration(validationError)
            }
            if config.useEncryption {
                guard let cryptProfile = configService.profile(for: config.cryptRemoteName),
                      cryptProfile.isCrypt else {
                    throw MountControllerError.encryptionNotConfigured
                }
            }

            try paths.prepareFileSystem()
            let targetPath = config.resolvedMountPath(
                volumesWritable: FileManager.default.isWritableFile(atPath: "/Volumes")
            )
            state.mountPath = targetPath
            state.volumeName = config.sanitizedVolumeName
            try await clearStaleMount(at: targetPath)
            try await prepareMountDirectory(at: targetPath)

            var diskSpaceTotal: Int64?
            do {
                if let about = try await configService.about(remoteName: config.remoteName) {
                    telemetry.about = about
                    diskSpaceTotal = about.effectiveTotal
                }
            } catch {
                NSLog("[DriveStream] Quota preflight failed: \(error.localizedDescription)")
            }

            let candidates = resolveBackendCandidates()
            guard !candidates.isEmpty else {
                throw MountControllerError.backendUnavailable(backendUnavailableMessage())
            }

            let parentFileSystem = MountProbe.filesystemType(atPath: targetPath)
            var attemptFailures: [String] = []

            for (index, backend) in candidates.enumerated() {
                try Task.checkCancellation()
                do {
                    try await startMount(
                        backend: backend,
                        targetPath: targetPath,
                        parentFileSystem: parentFileSystem,
                        diskSpaceTotal: diskSpaceTotal
                    )
                    if index > 0 {
                        showToast("Mounted with \(backend.displayName) as a fallback.")
                    }
                    return true
                } catch is CancellationError {
                    await abortMountAttempt()
                    throw CancellationError()
                } catch {
                    attemptFailures.append("\(backend.shortName): \(error.localizedDescription)")
                    await abortMountAttempt()
                    guard !hasMountSession else {
                        throw MountControllerError.mountFailed("The previous mount attempt is still attached. Retry unmounting before trying a different backend.")
                    }
                    if index + 1 < candidates.count {
                        try? await Task.sleep(for: .milliseconds(650))
                    }
                }
            }

            throw MountControllerError.mountFailed(
                "DriveStream could not mount the volume.\n\n" + attemptFailures.joined(separator: "\n\n")
            )
        } catch is CancellationError {
            await cleanupAfterFailedMount()
            state.status = hasMountSession ? .failed : .unmounted
            state.mountedAt = nil
            return false
        } catch {
            await cleanupAfterFailedMount()
            state.status = .failed
            state.mountedAt = nil
            let privateLog = activeLogURL != previousLogURL ? logExcerpt(limit: 4_000) : ""
            let issue = DriveStreamIssue.mountFailure(description: error.localizedDescription, log: privateLog)
            mountIssue = issue
            state.lastError = issue.summary
            errorMessage = issue.summary
            return false
        }
    }

    func unmount(allowPendingUploads: Bool = false) async {
        lifecycleEpoch += 1
        wasMountedBeforeSleep = false
        wakeRecoveryRequested = false
        if let recovery = wakeRecoveryTask {
            recovery.cancel()
            await recovery.value
        }
        if let unmountTask {
            await unmountTask.value
            return
        }
        guard !isUnmounting else { return }
        isUnmounting = true
        // A fresh unstructured Task does not inherit its caller's cancellation.
        // Detachment must finish even from a cancelled setup task; keep it joined.
        let cleanup = Task { @MainActor [self] in
            await performUnmount(allowPendingUploads: allowPendingUploads)
        }
        unmountTask = cleanup
        await cleanup.value
        unmountTask = nil
        isUnmounting = false
        if isMounted, rcloneProcess?.isRunning == true, !isSleeping { startTelemetry() }
    }

    private func performUnmount(allowPendingUploads: Bool) async {
        if let recoveryCleanupTask { await recoveryCleanupTask.value }
        if let mountTask {
            mountTask.cancel()
            _ = await mountTask.value
        }
        let targetPath = state.mountPath
        let process = rcloneProcess
        exitBlockedByWrites = false
        if !allowPendingUploads, ownsCurrentMount, process?.isRunning == true {
            let safety = await refreshWriteSafetyNow()
            if safety.requiresExitConsent {
                exitBlockedByWrites = true
                let issue = DriveStreamIssue(
                    title: safety.title,
                    summary: safety.detail + " Keep the app running, or explicitly confirm an interrupted exit.",
                    recovery: .retryUnmount
                )
                mountIssue = issue
                errorMessage = issue.summary
                return
            }
        }
        let mountIsActive = await mountInspector.isActive(path: targetPath)
        let mounted = isMounted || process != nil || (ownsCurrentMount && mountIsActive)
        guard mounted else {
            state.status = .unmounted
            state.mountedAt = nil
            state.backend = nil
            state.mountPath = resolvedDefaultMountPath()
            if !remoteIsConfigured {
                state.status = .unmounted
            }
            return
        }

        let previousStatus = state.status
        state.status = .unmounting
        cancelIndexing(resetStatus: false)
        stopTelemetry()
        presentationTask?.cancel()

        // A pin operation holds one file handle at a time. Cancel it and give it a
        // moment to close before rclone is asked to unmount.
        if pinTask != nil {
            pinTask?.cancel()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while pinTask != nil && clock.now < deadline {
                await pauseDuringCleanup(seconds: 0.1)
            }
        }

        if !allowPendingUploads, ownsCurrentMount, process?.isRunning == true {
            let detached = await mountInspector.unmountIfUnused(path: targetPath)
            if !detached {
                state.status = previousStatus
                let issue = DriveStreamIssue(title: "Files are still open on this volume",
                    summary: "macOS refused a normal unmount. Close applications using the drive and retry; its helper and cached files remain available.", recovery: .retryUnmount)
                mountIssue = issue
                errorMessage = issue.summary
                return
            }
        }
        if let process {
            _ = await RcloneProcessSupervisor.stop(process, policy: .normal)
        }

        if ownsCurrentMount, await mountInspector.isActive(path: targetPath) {
            _ = await mountInspector.forceUnmount(path: targetPath)
            _ = await waitUntilUnmounted(path: targetPath, timeout: 12)
        }

        let attachedAtPath = await mountInspector.isActive(path: targetPath)
        let stillMounted = ownsCurrentMount && attachedAtPath
        let processStillRunning = process?.isRunning == true
        state.volumeStillAttached = stillMounted
        state.mountedAt = nil
        if stillMounted || processStillRunning {
            state.status = .failed
            state.mountPath = targetPath
            let message = "Close apps using this volume, then retry unmounting. DriveStream has kept track of the remaining session."
            let issue = DriveStreamIssue(
                title: "The volume is still attached", summary: message,
                details: "rclone process still running: \(processStillRunning).\n\n" + DriveStreamIssue.privateLogNotice,
                recovery: .retryUnmount
            )
            mountIssue = issue
            state.lastError = message
            errorMessage = message
        } else {
            rcloneProcess = nil
            activeBackend = nil
            ownsCurrentMount = false
            rcClient.clearCredentials()
            state.backend = nil
            state.volumeStillAttached = false
            state.status = .unmounted
            state.lastError = nil
            errorMessage = nil
            state.mountPath = resolvedDefaultMountPath()
        }
        resetTelemetryActivity()
    }

    func toggleMount() async {
        if hasMountSession {
            await unmount()
        } else {
            _ = await mount()
        }
    }

    @discardableResult
    func shutdownForTermination(allowPendingUploads: Bool = false) async -> Bool {
        terminationInProgress = true
        lifecycleEpoch += 1
        wakeRecoveryRequested = false
        if let recovery = wakeRecoveryTask { recovery.cancel(); await recovery.value }
        mountTask?.cancel()
        connectionTask?.cancel()
        configurationTask?.cancel()
        dependencyManager.cancelPreparation()
        if let connectionTask { _ = try? await connectionTask.value }
        if let configurationTask { _ = try? await configurationTask.value }
        if let mountTask { _ = await mountTask.value }
        if let recoveryCleanupTask { await recoveryCleanupTask.value }
        if let unmountTask { await unmountTask.value }
        while isUnmounting {
            await pauseDuringCleanup(seconds: 0.15)
        }
        if !hasMountSession, !allowPendingUploads,
           let risk = lastPersistedWriteRisk, risk.state == .pending || risk.state == .blocked {
            exitBlockedByWrites = true
            uploadSafety = risk
            terminationInProgress = false
            return false
        }
        if hasMountSession {
            await unmount(allowPendingUploads: allowPendingUploads)
        } else if ownsCurrentMount, await mountInspector.isActive(path: state.mountPath) {
            _ = await mountInspector.forceUnmount(path: state.mountPath)
            state.volumeStillAttached = await mountInspector.isActive(path: state.mountPath)
            if !state.volumeStillAttached { ownsCurrentMount = false }
        }
        let safeToTerminate = !hasMountSession
        if !safeToTerminate { terminationInProgress = false }
        return safeToTerminate
    }

    /// Cancellation must not make cleanup polling busy-spin. This tiny detached
    /// sleeper is intentionally uncancelled; process waits themselves stay bounded.
    private func pauseDuringCleanup(seconds: TimeInterval) async {
        await RcloneProcessSupervisor.pauseDuringCleanup(seconds: seconds)
    }

    private func prepareMountDirectory(at path: String) async throws {
        guard path.hasPrefix("/"), path != "/" else {
            throw MountControllerError.invalidConfiguration("The mount point must be a folder, not the filesystem root.")
        }
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            throw MountControllerError.invalidConfiguration("The mount point must not be a symbolic link.")
        }
        let dsStore = url.appendingPathComponent(".DS_Store")
        try? fileManager.removeItem(at: dsStore)
        let contents = try fileManager.contentsOfDirectory(atPath: path)
        guard contents.isEmpty else {
            let sample = contents.prefix(4).joined(separator: ", ")
            throw MountControllerError.invalidConfiguration(
                "The mount folder at \(path) is not empty (\(sample)). Move its contents, then try again."
            )
        }
    }

    private func clearStaleMount(at path: String) async throws {
        if await mountInspector.isActive(path: path) {
            throw MountControllerError.mountFailed(
                "Another volume is still mounted at \(path). Unmount it in Finder or choose a different mount folder. DriveStream will not detach a volume it does not own."
            )
        }
    }

    private func resolveBackendCandidates() -> [VolumeBackend] {
        if let backendCandidates { return backendCandidates }
        let availability = dependencyManager.refreshFuseAvailability()
        let nfsSupported = dependencyManager.supportsNFSMount
        var candidates: [VolumeBackend] = []

        switch config.mountBackend {
        case .nfs:
            if nfsSupported { candidates.append(.nfs) }
        case .macFUSE, .auto:
            if availability.macFUSEInstalled { candidates.append(.macFUSE) }
            if availability.fuseTInstalled { candidates.append(.fuseT) }
            if nfsSupported { candidates.append(.nfs) }
        }
        return candidates
    }

    private func backendUnavailableMessage() -> String {
        if config.mountBackend == .nfs && !dependencyManager.supportsNFSMount {
            return "The built-in NFS backend requires rclone 1.65 or newer. Reinstall rclone from Settings."
        }
        return "No compatible filesystem backend is available. Install macFUSE for the FUSE backend, or use the built-in NFS backend with a current rclone build."
    }

    private func startMount(
        backend: VolumeBackend,
        targetPath: String,
        parentFileSystem: String?,
        diskSpaceTotal: Int64?
    ) async throws {
        state.backend = backend
        state.status = .mounting
        activeBackend = backend

        try paths.prepareFileSystem()
        let logURL = try RcloneProcessSupervisor.createLog(paths: paths, backend: backend)
        activeLogURL = logURL
        activeLogPath = logURL.path

        rcClient.clearCredentials()
        rcPassword = Self.generateRCPassword()
        let arguments = try await buildMountArguments(
            backend: backend,
            targetPath: targetPath,
            logURL: logURL,
            diskSpaceTotal: diskSpaceTotal,
            rcPassword: rcPassword
        )

        processGeneration += 1
        let generation = processGeneration
        let process: Process
        do {
            process = try RcloneProcessSupervisor.launch(
                executableURL: dependencyManager.rcloneBinaryURL, arguments: arguments,
                workingDirectory: paths.applicationSupportDirectory, rcPassword: rcPassword
            ) { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.handleRcloneTermination(status: status, generation: generation)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MountControllerError.mountFailed("Could not launch rclone: \(error.localizedDescription)")
        }
        rcloneProcess = process
        ownsCurrentMount = true

        try await waitForMount(
            process: process,
            targetPath: targetPath,
            parentFileSystem: parentFileSystem,
            backend: backend
        )

        try Task.checkCancellation()
        // A process can theoretically exit in the tiny window between readiness
        // detection and this transition. Do not advertise a dead mount.
        guard process.isRunning else {
            throw MountControllerError.mountFailed(
                "rclone exited immediately after the volume became ready.\n\n" + DriveStreamIssue.privateLogNotice
            )
        }

        state.status = .mounted
        state.backend = backend
        state.mountPath = targetPath
        state.volumeName = config.sanitizedVolumeName
        state.mountedAt = Date()
        state.lastError = nil
        errorMessage = nil
        mountIssue = nil
        telemetryCoordinator.resetSessionMetrics()
        startTelemetry()
        startVolumePresentation(mountPath: targetPath)
        beginIndexing(isInitial: true)
        scheduleQueueRefresh(core: nil, vfs: nil)
    }

    private func waitForMount(
        process: Process,
        targetPath: String,
        parentFileSystem: String?,
        backend: VolumeBackend
    ) async throws {
        let timeout: TimeInterval = backend.usesFUSE ? 90 : 60
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var nextMountTableCheck = clock.now
        var controlServerVerified = false

        while clock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw MountControllerError.mountFailed(mountFailureMessage(backend: backend))
            }

            if rcClient.baseURL == nil,
               let logURL = activeLogURL,
               let endpoint = RCServerEndpoint.readAnnouncement(from: logURL) {
                try rcClient.configure(baseURL: endpoint, username: rcUsername, password: rcPassword)
            }
            if !controlServerVerified, rcClient.baseURL != nil,
               let processID = try? await rcClient.processID() {
                guard processID == Int(process.processIdentifier) else {
                    throw MountControllerError.mountFailed("The control server did not belong to the rclone process launched by DriveStream.")
                }
                controlServerVerified = true
            }
            let reachable = controlServerVerified
            if reachable {
                if clock.now >= nextMountTableCheck {
                    nextMountTableCheck = clock.now.advanced(by: .seconds(0.8))
                    if await mountInspector.isActive(path: targetPath) { return }
                }
                if let parentFileSystem,
                   let current = MountProbe.filesystemType(atPath: targetPath),
                   current != parentFileSystem {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(reachable ? 250 : 400))
        }

        throw MountControllerError.mountFailed(mountFailureMessage(backend: backend))
    }

    private func mountFailureMessage(backend: VolumeBackend) -> String {
        var message: String
        if processExitedBeforeReady {
            message = "rclone exited before the volume became available."
        } else {
            message = "The mount did not become ready in time."
        }
        if backend == .macFUSE || backend == .fuseT {
            message += "\n\nCheck the installed driver and macOS approval state. Actual FSKit/kernel mode depends on driver and rclone integration; built-in NFS is available as an alternative."
        } else {
            message += "\n\nThe built-in NFS backend uses the macOS mount helper. Check the mount folder and close apps holding the volume open."
        }
        message += "\n\n" + DriveStreamIssue.privateLogNotice
        return message
    }

    private var processExitedBeforeReady: Bool {
        guard let rcloneProcess else { return true }
        return !rcloneProcess.isRunning
    }

    private func buildMountArguments(
        backend: VolumeBackend,
        targetPath: String,
        logURL: URL,
        diskSpaceTotal: Int64?,
        rcPassword: String
    ) async throws -> [String] {
        let help = await dependencyManager.commandHelp(for: backend.mountSubcommand)
        let cache = try RcloneDriveRootService.prepareCacheDirectory(
            namespace: configService.profile(for: config.remoteName)?.cacheNamespace, root: paths.cacheDirectory
        )
        return MountArgumentsBuilder.build(
            config: config, paths: paths, backend: backend, help: help,
            mountPath: targetPath, logURL: logURL, diskSpaceTotal: diskSpaceTotal,
            username: rcUsername, password: rcPassword, cacheDirectory: cache
        )
    }

    // MARK: Post-mount

    private func startVolumePresentation(mountPath: String) {
        guard enableFinderIntegration else { return }
        presentationTask?.cancel()
        let suppressSpotlight = config.suppressSpotlightIndexing
        let showDesktopIcons = config.showDriveOnDesktop
        presentationTask = Task.detached(priority: .utility) {
            await VolumePresenter.prepare(
                mountPath: mountPath,
                suppressSpotlight: suppressSpotlight,
                showDesktopIcons: showDesktopIcons
            )
        }
    }

    private func beginIndexing(isInitial: Bool) {
        guard isMounted else { return }
        indexingTask?.cancel()
        indexingGeneration += 1
        let generation = indexingGeneration
        isIndexing = true
        refreshInProgress = true
        indexingStartedAt = Date()
        state.status = .indexing

        indexingTask = Task { [weak self] in
            guard let self else { return }
            var consecutiveStatusFailures = 0
            do {
                // A lost HTTP response may still have started the remote job.
                // Issue this side effect exactly once; only status reads may retry.
                let response = try await self.rcClient.refresh()
                guard let jobID = response.jobid, jobID > 0 else {
                    throw RcloneRCError.decoding(path: "vfs/refresh", message: "No asynchronous job ID was returned.")
                }

                while !Task.isCancelled {
                    do {
                        let status = try await self.rcClient.jobStatus(jobID: jobID)
                        consecutiveStatusFailures = 0
                        if status.finished {
                            self.finishIndexing(
                                generation: generation,
                                succeeded: status.succeeded,
                                message: status.errorMessage,
                                wasInitial: isInitial
                            )
                            return
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard (error as? RcloneRCError)?.isTransient == true else { throw error }
                        consecutiveStatusFailures += 1
                        if consecutiveStatusFailures >= 5 { throw error }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {
                return
            } catch {
                self.finishIndexing(
                    generation: generation,
                    succeeded: false,
                    message: error.localizedDescription,
                    wasInitial: isInitial
                )
            }
        }

        if !isInitial {
            showToast("Refreshing the directory tree in the background…")
        }
    }

    private func finishIndexing(
        generation: Int,
        succeeded: Bool,
        message: String?,
        wasInitial: Bool
    ) {
        guard generation == indexingGeneration else { return }
        isIndexing = false
        indexingStartedAt = nil
        refreshInProgress = false
        indexingTask = nil
        if isMounted, state.status != .unmounting {
            state.status = .mounted
        }
        guard succeeded else {
            let detail = (message?.isEmpty == false ? message! : "rclone did not report a reason.")
            errorMessage = "The recursive directory pre-warm did not finish: \(detail). Finder listings will fill the cache on demand."
            return
        }
        if !wasInitial {
            showToast("Directory tree refreshed.")
        }
    }

    func forceRefreshDirectoryTree() {
        guard isMounted else {
            showToast("Mount the volume before refreshing it.")
            return
        }
        guard !refreshInProgress else { return }
        beginIndexing(isInitial: false)
    }

    private func cancelIndexing(resetStatus: Bool) {
        indexingGeneration += 1
        indexingTask?.cancel()
        indexingTask = nil
        isIndexing = false
        refreshInProgress = false
        indexingStartedAt = nil
        if resetStatus, isMounted {
            state.status = .mounted
        }
    }

    // MARK: Telemetry

    private func startTelemetry() {
        stopTelemetry()
        telemetryWarning = nil
        quotaWarning = nil
        let generation = processGeneration
        telemetryCoordinator.start(
            session: .init(client: rcClient, remote: config.effectiveRemoteSpecifier,
                           quotaRemote: config.quotaRemoteSpecifier,
                           remoteNames: [config.remoteName, config.cryptRemoteName]),
            initialSnapshot: telemetry, networkAvailable: connectivity != .unavailable
        ) { [weak self] update in
            guard let self, generation == self.processGeneration, self.isMounted,
                  !self.isUnmounting, !self.isSleeping else { return }
            switch update {
            case .activity(let snapshot, let reading):
                self.telemetry = snapshot
                self.telemetryWarning = nil
                self.telemetryIsStale = false
                self.scheduleQueueRefresh(core: reading.core, vfs: reading.vfs)
            case .activityUnavailable(let warning):
                self.telemetryIsStale = true
                if let warning { self.telemetryWarning = warning }
            case .quota(let about):
                self.telemetry.about = about
                self.quotaWarning = nil
            case .quotaUnavailable(let warning):
                self.quotaWarning = warning
            case .retrying(let inProgress):
                self.telemetryRetryInProgress = inProgress
            }
        }
    }

    /// Replace the poll task to make Retry Now immediate even during backoff.
    func refreshTelemetryNow() {
        guard isMounted, !isUnmounting, !isSleeping else { return }
        telemetryCoordinator.setNetworkAvailable(connectivity != .unavailable)
        telemetryCoordinator.refreshNow()
    }

    private func scheduleQuotaRefresh() {
        guard isMounted, !isUnmounting, !isSleeping else { return }
        telemetryCoordinator.setNetworkAvailable(connectivity != .unavailable)
        telemetryCoordinator.requestQuotaRefresh()
    }

    private func stopTelemetry() {
        telemetryCoordinator.stop()
        queueTask?.cancel()
        queueTask = nil
        queueRequestID = nil
        telemetryRetryInProgress = false
    }

    private func resetTelemetryActivity() {
        telemetry = telemetryCoordinator.resetActivity(from: telemetry)
        telemetryWarning = nil
        quotaWarning = nil
        telemetryIsStale = false
    }

    // MARK: Pending writes and machine lifecycle

    @discardableResult
    func refreshWriteSafetyNow() async -> UploadSafetySnapshot {
        guard let process = rcloneProcess, process.isRunning, let endpoint = rcClient.baseURL else {
            return .unavailable("No active helper can verify pending writes. Stored observations do not authorize an exit.")
        }
        if let task = writeCheckTask, writeCheckGeneration == processGeneration { return await task.value }
        writeCheckTask?.cancel()
        queueTask?.cancel()
        queueTask = nil
        queueRequestID = nil
        let generation = processGeneration
        let remote = config.effectiveRemoteSpecifier
        let requestID = UUID()
        writeCheckID = requestID
        writeCheckGeneration = generation
        isCheckingWrites = true
        let task = Task { [weak self] () -> UploadSafetySnapshot in
            guard let self else { return .unavailable("The application is shutting down.") }
            defer {
                if self.writeCheckID == requestID {
                    self.writeCheckTask = nil
                    self.writeCheckID = nil
                    self.isCheckingWrites = false
                }
            }
            do {
                let safety = try await self.writeSafetyReader.read(client: self.rcClient, remote: remote)
                try Task.checkCancellation()
                guard self.writeCheckID == requestID, generation == self.processGeneration,
                      self.rcloneProcess === process, process.isRunning,
                      self.rcClient.baseURL == endpoint, self.config.effectiveRemoteSpecifier == remote,
                      safety.isFresh else { return .unavailable("The write-status response was stale or belonged to an old session.") }
                self.publishWriteSafety(safety, authoritative: true)
                return safety
            } catch {
                let unknown = UploadSafetySnapshot.unavailable("Pending writes could not be verified. Keep the app and cache available or explicitly confirm an interrupted exit.")
                if self.writeCheckID == requestID, generation == self.processGeneration, self.rcloneProcess === process {
                    self.publishWriteSafety(unknown)
                }
                return unknown
            }
        }
        writeCheckTask = task
        return await task.value
    }

    private func publishWriteSafety(_ safety: UploadSafetySnapshot, authoritative: Bool = false) {
        uploadSafety = safety
        let old = lastPersistedWriteRisk
        // Preserve a known pending warning if a later read is unavailable. Avoid
        // rewriting a tiny ledger on every idle poll just for a changed timestamp.
        guard safety.state != .unknown, safety.state != .idleObserved || authoritative,
              old?.state != safety.state || old?.pendingFiles != safety.pendingFiles
                || old?.pendingBytes != safety.pendingBytes || old?.detail != safety.detail else { return }
        guard ContinuousClock.now >= nextWriteRiskRetry else { return }
        if WriteRiskStore.record(safety, paths: paths) {
            lastPersistedWriteRisk = safety
        } else {
            nextWriteRiskRetry = ContinuousClock.now.advanced(by: .seconds(5))
        }
    }

    private func scheduleQueueRefresh(core: RcloneCoreStats?, vfs: RcloneVFSStats?) {
        guard queueTask == nil, writeCheckTask == nil, isMounted, !isUnmounting, !isSleeping else { return }
        let generation = processGeneration
        let requestID = UUID()
        queueRequestID = requestID
        queueTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.queueRequestID == requestID {
                    self.queueTask = nil
                    self.queueRequestID = nil
                }
            }
            do {
                let safety: UploadSafetySnapshot
                if let core, let vfs {
                    let queue = try await self.rcClient.uploadQueue()
                    safety = UploadSafetySnapshot.assess(queue: queue, vfs: vfs, core: core)
                } else {
                    safety = try await self.writeSafetyReader.read(client: self.rcClient, remote: self.config.effectiveRemoteSpecifier)
                }
                try Task.checkCancellation()
                guard self.queueRequestID == requestID, generation == self.processGeneration, self.isMounted, !self.isUnmounting else { return }
                self.publishWriteSafety(safety)
            } catch is CancellationError { return }
            catch {
                guard self.queueRequestID == requestID, generation == self.processGeneration, self.isMounted, !self.isUnmounting else { return }
                self.publishWriteSafety(.unavailable("Live cloud-write status is unavailable. Last cache data remains local; retry before an exit decision."))
            }
        }
    }

    func handleDeviceLifecycle(_ event: DeviceLifecycleEvent) {
        switch event {
        case .willSleep:
            lifecycleEpoch += 1
            wasMountedBeforeSleep = wasMountedBeforeSleep || hasMountSession
            isSleeping = true
            wakeRecoveryRequested = false
            wakeRecoveryTask?.cancel()
            stopTelemetry()
            // Do not pretend a sleep notification gives time to upload a library.
            // Keep the local server/cache attached so Finder identity survives.
        case .didWake:
            isSleeping = false
            recoverAfterWake()
        case .network(let state):
            let changed = state != connectivity
            connectivity = state
            guard changed, !isSleeping, !terminationInProgress else { return }
            if isMounted {
                refreshTelemetryNow()
                if state == .available { scheduleQuotaRefresh() }
            } else if state == .available && wasMountedBeforeSleep {
                recoverAfterWake()
            }
        }
    }

    private func recoverAfterWake() {
        guard !terminationInProgress, !isUnmounting, !isSleeping else { return }
        if wakeRecoveryTask != nil {
            wakeRecoveryRequested = true
            return
        }
        let epoch = lifecycleEpoch
        let generation = processGeneration
        let requestID = UUID()
        wakeRequestID = requestID
        wakeRecoveryRequested = false
        wakeRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.wakeRequestID == requestID {
                    self.wakeRecoveryTask = nil
                    self.wakeRequestID = nil
                    if self.wakeRecoveryRequested, !self.isSleeping, !self.terminationInProgress {
                        self.wakeRecoveryRequested = false
                        self.recoverAfterWake()
                    }
                }
            }
            @MainActor func current() -> Bool {
                self.wakeRequestID == requestID && self.lifecycleEpoch == epoch
                    && !Task.isCancelled && !self.isSleeping && !self.terminationInProgress
            }
            if let process = self.rcloneProcess, process.isRunning {
                let actualPID = try? await self.rcClient.processID()
                guard current(), generation == self.processGeneration, self.rcloneProcess === process else { return }
                if actualPID == Int(process.processIdentifier), process.isRunning, self.isMounted {
                    self.startTelemetry()
                    if self.connectivity != .unavailable { self.scheduleQuotaRefresh() }
                    self.wasMountedBeforeSleep = false
                } else {
                    self.telemetryWarning = "The helper has not recovered after wake. Attachment is preserved; inspect cached writes before restarting."
                    if self.isMounted { self.refreshTelemetryNow() }
                }
            } else if self.wasMountedBeforeSleep, self.config.recoverMountAfterWake,
                      self.connectivity != .unavailable {
                if let cleanup = self.recoveryCleanupTask { await cleanup.value }
                guard current(), !self.hasMountSession else { return }
                let mounted = await self.mountVolume(allowOwnedConfigurationOperation: false)
                guard current() else { return }
                // Failure preserves the recovery intent for a later available path;
                // an older cancelled task must not overwrite a newer sleep event.
                if mounted { self.wasMountedBeforeSleep = false }
            }
        }
    }

    // MARK: Process lifecycle

    private func handleRcloneTermination(status: Int32, generation: Int) {
        guard generation == processGeneration else { return }
        let tail = logExcerpt(limit: 4_000)
        writeCheckTask?.cancel()
        writeCheckID = nil
        writeCheckTask = nil
        isCheckingWrites = false
        rcloneProcess = nil
        if isUnmounting || state.status == .unmounting { return }

        switch state.status {
        case .mounting, .preparing:
            return
        case .mounted, .indexing:
            stopTelemetry()
            cancelIndexing(resetStatus: false)
            pinTask?.cancel()
            state.status = .failed
            state.mountedAt = nil
            let message = "rclone stopped unexpectedly (exit status \(status))."
            let cause = DriveStreamIssue.mountFailure(description: message, log: tail)
            let issue = DriveStreamIssue(
                title: cause.title, summary: cause.summary,
                details: "rclone exit status: \(status).\n\n" + DriveStreamIssue.privateLogNotice,
                recovery: cause.recovery
            )
            mountIssue = issue
            state.lastError = issue.summary
            errorMessage = issue.summary
            rcClient.clearCredentials()
            let path = state.mountPath
            state.volumeStillAttached = ownsCurrentMount
            recoveryCleanupTask = Task { @MainActor [weak self] in
                guard let self, generation == self.processGeneration, self.ownsCurrentMount else { return }
                defer {
                    if generation == self.processGeneration { self.recoveryCleanupTask = nil }
                }
                let attached = await self.mountInspector.isActive(path: path)
                guard generation == self.processGeneration, self.ownsCurrentMount else { return }
                if attached { _ = await self.mountInspector.forceUnmount(path: path) }
                let remainsAttached = await self.mountInspector.isActive(path: path)
                guard generation == self.processGeneration, self.ownsCurrentMount else { return }
                self.state.volumeStillAttached = remainsAttached
                if !remainsAttached { self.ownsCurrentMount = false }
            }
        case .unmounted, .failed:
            break
        case .unmounting:
            break
        }
    }

    private func abortMountAttempt() async {
        // Cancellation propagates into CommandRunner. Run probes and unmount
        // commands in a fresh, joined unstructured task (no inherited cancellation),
        // not in the cancelled mount attempt.
        await Task { @MainActor [self] in
            await performAbortMountAttempt()
        }.value
    }

    private func performAbortMountAttempt() async {
        let targetPath = state.mountPath
        if let process = rcloneProcess {
            _ = await RcloneProcessSupervisor.stop(process, policy: .failedStartup)
        }
        if ownsCurrentMount, await mountInspector.isActive(path: targetPath) {
            _ = await mountInspector.forceUnmount(path: targetPath)
            _ = await waitUntilUnmounted(path: targetPath, timeout: 8)
        }
        let attached = ownsCurrentMount ? await mountInspector.isActive(path: targetPath) : false
        state.volumeStillAttached = attached
        if rcloneProcess?.isRunning != true, !attached {
            rcloneProcess = nil
            activeBackend = nil
            ownsCurrentMount = false
            rcClient.clearCredentials()
        }
    }

    private func cleanupAfterFailedMount() async {
        stopTelemetry()
        cancelIndexing(resetStatus: false)
        await abortMountAttempt()
        resetTelemetryActivity()
        state.backend = nil
    }

    private func waitUntilUnmounted(path: String, timeout: TimeInterval) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline {
            if !(await mountInspector.isActive(path: path)) { return true }
            await pauseDuringCleanup(seconds: 0.25)
        }
        return !(await mountInspector.isActive(path: path))
    }

    private func logExcerpt(limit: Int) -> String {
        RcloneProcessSupervisor.logExcerpt(at: activeLogURL ?? paths.latestLogFile(), limit: limit)
    }

    private func resolvedDefaultMountPath() -> String {
        config.resolvedMountPath(volumesWritable: FileManager.default.isWritableFile(atPath: "/Volumes"))
    }

    // MARK: Finder services: pinning and eviction

    func pinOffline(urls: [URL]) async throws -> PinResult {
        guard isMounted, !isUnmounting, !isSleeping else { throw MountControllerError.notMounted }
        guard pinTask == nil else {
            throw MountControllerError.operationInProgress("Offline pinning")
        }
        let normalized = try normalizeSelectedURLs(urls)
        guard !normalized.urls.isEmpty else {
            throw MountControllerError.invalidConfiguration("Select at least one file or folder inside the DriveStream volume.")
        }
        let path = mountPath
        var progressValue = PinProgress()
        progressValue.phase = .scanning
        progressValue.startedAt = Date()
        pinProgress = progressValue

        let operationID = UUID()
        pinOperationID = operationID
        let maximumReaders = config.performancePolicy.pinConcurrency
        let task = Task.detached(priority: .utility) { () async throws -> PinResult in
            try await PinEngine.pin(
                roots: normalized.urls,
                mountPath: path,
                relativePaths: normalized.relativePaths,
                maximumConcurrentFiles: maximumReaders,
                progress: { snapshot in
                    Task { @MainActor in
                        guard self.pinOperationID == operationID, self.pinProgress != nil else { return }
                        self.pinProgress = snapshot
                    }
                }
            )
        }
        pinTask = task

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            pinTask = nil
            pinProgress = nil
            pinOperationID = nil
            pinnedPaths.subtract(normalized.relativePaths)
            pinnedPaths.formUnion(result.pinnedPaths)
            PinnedPathStore.save(pinnedPaths, to: defaults)
            var message = "Cached \(result.filesRead) file\(result.filesRead == 1 ? "" : "s") (\(ByteFormat.bytes(result.bytesRead))). Cache policy still applies."
            if result.failedFiles > 0 {
                message += " \(result.failedFiles) read/traversal failure\(result.failedFiles == 1 ? "" : "s") reported."
            }
            showToast(message)
            return result
        } catch {
            pinTask = nil
            pinProgress = nil
            pinOperationID = nil
            if error is CancellationError {
                showToast("Offline pinning was canceled.")
                throw error
            }
            errorMessage = "Offline pinning failed: \(error.localizedDescription)"
            throw error
        }
    }

    func cancelPinning() {
        guard pinTask != nil else { return }
        pinTask?.cancel()
        showToast("Canceling offline pinning…")
    }

    func evict(paths urls: [URL]) async throws -> EvictionResult {
        guard isMounted else { throw MountControllerError.notMounted }
        let normalized = try normalizeSelectedURLs(urls)
        var evicted: [String] = []
        var failures: [String] = []

        for (url, relativePath) in zip(normalized.urls, normalized.relativePaths) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            do {
                _ = try await rcClient.forget(
                    relativePath: relativePath,
                    isDirectory: isDirectory,
                    remote: config.effectiveRemoteSpecifier
                )
                evicted.append(relativePath)
                removePinnedPaths(equalToOrUnder: relativePath)
            } catch {
                failures.append("\(relativePath): \(error.localizedDescription)")
            }
        }

        if evicted.isEmpty, !failures.isEmpty {
            throw MountControllerError.mountFailed(
                "Could not evict the selected items.\n\n" + failures.joined(separator: "\n")
            )
        }

        if !evicted.isEmpty {
            showToast("Eviction requested for \(evicted.count) item\(evicted.count == 1 ? "" : "s"). rclone reclaims cached blocks under its cache policy.")
        }
        return EvictionResult(evictedPaths: evicted, failures: failures)
    }

    func freeUpSpaceNow() async {
        guard isMounted else {
            showToast("Mount the volume before freeing local cache space.")
            return
        }
        guard !freeUpInProgress else { return }
        freeUpInProgress = true
        defer { freeUpInProgress = false }

        do {
            // rclone's RC API has no live cache-block purge. `options/set` writes
            // the global option defaults, but a running mount owns a *copy* of the
            // VFS options (mountlib copies them, then vfs.New copies them again), so
            // changing CacheMaxSize there cannot evict chunks from this mount.
            // Deleting files inside the live cache is unsafe for open streams and
            // queued write-back data. The supported safe operation is vfs/forget;
            // rclone's cache cleaner reclaims unpinned blocks under the configured
            // max-size/max-age policy.
            let generation = processGeneration
            _ = try await rcClient.forgetAll(remote: config.effectiveRemoteSpecifier)
            try Task.checkCancellation()
            guard generation == processGeneration, isMounted, !isUnmounting else { return }
            if let stats = try? await rcClient.vfsStats(remote: config.effectiveRemoteSpecifier),
               generation == processGeneration, isMounted, !isUnmounting {
                telemetry.vfs = stats
                telemetry.cacheBytes = stats.cacheBytesUsed
            }
            showToast("Cache cleanup requested. rclone’s cache manager reclaims unpinned blocks under your cap and age policy.")
        } catch {
            errorMessage = "Could not request local cache cleanup: \(error.localizedDescription)"
        }
    }

    private func normalizeSelectedURLs(_ urls: [URL]) throws -> (urls: [URL], relativePaths: [String]) {
        let root = URL(fileURLWithPath: mountPath).resolvingSymlinksInPath().standardizedFileURL
        var normalized: [URL] = []
        var relative: [String] = []
        var seen = Set<String>()
        for url in urls {
            let lexical = url.standardizedFileURL
            let mountLexical = URL(fileURLWithPath: mountPath).standardizedFileURL
            let lexicalBase = lexical.path.hasPrefix(mountLexical.path + "/") ? mountLexical : root
            guard lexical.path.hasPrefix(lexicalBase.path + "/") else {
                throw MountControllerError.pathOutsideVolume(url.path)
            }
            let components = lexical.path.dropFirst(lexicalBase.path.count + 1).split(separator: "/")
            var selected = root
            for component in components {
                selected.appendPathComponent(String(component))
                if (try? selected.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw MountControllerError.invalidConfiguration("Select an ordinary file or directory, not a symbolic-link path.")
                }
            }
            let resolved = selected.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
                throw MountControllerError.pathOutsideVolume(url.path)
            }
            if resolved.path == root.path {
                throw MountControllerError.invalidConfiguration(
                    "Select a file or folder inside the volume rather than the volume root."
                )
            }
            guard seen.insert(resolved.path).inserted else { continue }
            let relativePath = String(resolved.path.dropFirst(root.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else { continue }
            normalized.append(resolved)
            relative.append(relativePath)
        }
        return (normalized, relative)
    }

    private func removePinnedPaths(equalToOrUnder relativePath: String) {
        let prefix = relativePath + "/"
        let newValue = pinnedPaths.filter { $0 != relativePath && !$0.hasPrefix(prefix) }
        if newValue != pinnedPaths {
            pinnedPaths = newValue
            PinnedPathStore.save(pinnedPaths, to: defaults)
        }
    }

    // MARK: Connection management

    func availableSharedDrives() async throws -> [GoogleSharedDrive] {
        guard remoteIsConfigured else { throw DriveRootError.notConnected }
        let generation = accountGeneration
        let remote = config.remoteName
        let drives = try await configService.sharedDrives(remoteName: remote)
        try Task.checkCancellation()
        guard generation == accountGeneration, remoteIsConfigured, remote == config.remoteName else { throw CancellationError() }
        return drives
    }

    func connectGoogleDrive(
        useCustomCredentials: Bool,
        clientID: String,
        clientSecret: String
    ) async throws {
        guard connectionTask == nil, configurationTask == nil, recoveryCleanupTask == nil,
              !mountOperationInProgress, !isUnmounting, !terminationInProgress, !freeUpInProgress else {
            throw MountControllerError.operationInProgress("Google sign-in")
        }
        let task = Task {
            try await performGoogleConnection(
                useCustomCredentials: useCustomCredentials,
                clientID: clientID,
                clientSecret: clientSecret
            )
        }
        connectionTask = task
        defer { connectionTask = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelGoogleConnection() {
        connectionTask?.cancel()
    }

    private func performGoogleConnection(
        useCustomCredentials: Bool,
        clientID: String,
        clientSecret: String
    ) async throws {
        guard !isConnecting else {
            throw MountControllerError.operationInProgress("Google sign-in")
        }

        isConnecting = true
        connectionMessage = "Preparing Google sign-in…"
        defer {
            isConnecting = false
            connectionMessage = nil
        }

        let dependenciesReady = await dependencyManager.prepare()
        try Task.checkCancellation()
        guard dependenciesReady else {
            throw MountControllerError.dependencyUnavailable(
                dependencyManager.lastError ?? "rclone is not installed."
            )
        }

        // Never rewrite rclone.conf while the mount process is running: rclone can
        // refresh and persist its token concurrently. A deliberate credential change
        // gets a clean restart after the new token has been verified.
        let wasMounted = hasMountSession
        if wasMounted {
            await unmount()
            if hasMountSession {
                throw MountControllerError.mountFailed(
                    "The volume could not be unmounted; close apps using it before reconnecting Google Drive."
                )
            }
        }
        connectionMessage = "Complete the Google sign-in in your browser…"

        do {
            let result = try await configService.connectGoogleDrive(
                remoteName: config.remoteName,
                clientID: useCustomCredentials ? clientID : "",
                clientSecret: useCustomCredentials ? clientSecret : ""
            )
            try Task.checkCancellation()
            remoteIsConfigured = true
            config.usesCustomOAuth = result.usesCustomOAuth
            config.clientID = result.usesCustomOAuth
                ? (result.profile.clientID ?? clientID.trimmingCharacters(in: .whitespacesAndNewlines))
                : ""
            config.accountEmail = result.account?.email ?? result.account?.displayName ?? ""
            config.sharedDriveID = result.profile.sharedDriveID ?? ""
            accountGeneration = UUID()
            accountLabel = result.account?.displayLabel
            if let about = result.about { telemetry.about = about }
            StreamConfigStore.save(config, to: defaults)
            errorMessage = nil
            showToast("Connected to Google Drive.")
            if wasMounted {
                _ = await mountVolume(allowOwnedConfigurationOperation: true)
            }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func reconnectGoogleDrive() async throws {
        if config.usesCustomOAuth {
            guard !config.clientID.isEmpty else {
                throw RcloneConfigError.invalidClientCredentials(
                    "The custom OAuth Client ID is missing. Re-enter your credentials in the Setup Assistant."
                )
            }
            guard let secret = configService.storedClientSecret(), !secret.isEmpty else {
                throw RcloneConfigError.invalidClientCredentials(
                    "The custom OAuth Client Secret is no longer in the Keychain. Re-enter it in the Setup Assistant."
                )
            }
            try await connectGoogleDrive(useCustomCredentials: true, clientID: config.clientID, clientSecret: secret)
        } else {
            try await connectGoogleDrive(useCustomCredentials: false, clientID: "", clientSecret: "")
        }
    }

    func completeOnboarding(
        volumeName: String,
        enableEncryption: Bool,
        cryptPassword: String,
        cryptSaltPassword: String,
        autoMount: Bool,
        mountBackend: MountBackendPreference,
        mountLocation: MountLocationPreference,
        cacheMaxSize: String
    ) async throws {
        try await runConfigurationOperation {
            try await self.performOnboarding(
                volumeName: volumeName, enableEncryption: enableEncryption,
                cryptPassword: cryptPassword, cryptSaltPassword: cryptSaltPassword,
                autoMount: autoMount, mountBackend: mountBackend,
                mountLocation: mountLocation, cacheMaxSize: cacheMaxSize
            )
        }
    }

    private func runConfigurationOperation(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        guard configurationTask == nil, connectionTask == nil, recoveryCleanupTask == nil,
              !mountOperationInProgress, !isUnmounting, !terminationInProgress else {
            throw MountControllerError.operationInProgress("Configuration changes")
        }
        let task = Task { try await operation() }
        configurationTask = task
        defer { configurationTask = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func performOnboarding(
        volumeName: String,
        enableEncryption: Bool,
        cryptPassword: String,
        cryptSaltPassword: String,
        autoMount: Bool,
        mountBackend: MountBackendPreference,
        mountLocation: MountLocationPreference,
        cacheMaxSize: String
    ) async throws {
        try Task.checkCancellation()
        guard remoteIsConfigured || configService.remoteExists(config.remoteName) else {
            throw MountControllerError.notConnected
        }
        if !remoteIsConfigured {
            refreshConnectionState()
        }
        var draft = config
        draft.volumeName = volumeName
        draft.autoMountOnLaunch = autoMount
        draft.mountBackend = mountBackend
        draft.mountLocation = mountLocation
        draft.cacheMaxSize = cacheMaxSize
        if let validationError = draft.validationError {
            throw MountControllerError.invalidConfiguration(validationError)
        }

        let wasMounted = hasMountSession
        if wasMounted {
            await unmount()
            if hasMountSession {
                throw MountControllerError.mountFailed(
                    "The volume could not be unmounted. Close apps using it, then reopen the Setup Assistant."
                )
            }
        }

        if enableEncryption {
            let existingCrypt = configService.profile(for: draft.cryptRemoteName)?.isCrypt == true
            if !existingCrypt || !cryptPassword.isEmpty {
                guard !cryptPassword.isEmpty else { throw MountControllerError.cryptPasswordMissing }
                _ = try await configService.configureCrypt(
                    remoteName: draft.remoteName,
                    cryptRemoteName: draft.cryptRemoteName,
                    password: cryptPassword,
                    saltPassword: cryptSaltPassword
                )
            }
        }
        try Task.checkCancellation()
        draft.useEncryption = enableEncryption
        draft.hasCompletedOnboarding = true

        config = draft
        StreamConfigStore.save(config, to: defaults)
        state.volumeName = config.sanitizedVolumeName
        state.mountPath = resolvedDefaultMountPath()
        errorMessage = nil

        if autoMount {
            let mounted = await mountVolume(allowOwnedConfigurationOperation: true)
            if !mounted {
                throw MountControllerError.mountFailed(
                    state.lastError ?? "The volume could not be mounted. Check the DriveStream menu for details."
                )
            }
        } else {
            state.status = .unmounted
        }
    }

    func applySettings(_ newConfig: StreamConfig) async throws {
        guard !isBusy else {
            throw MountControllerError.operationInProgress("Another DriveStream operation")
        }
        try await runConfigurationOperation {
            try await self.performSettingsChange(newConfig)
        }
    }

    private func performSettingsChange(_ newConfig: StreamConfig) async throws {
        try Task.checkCancellation()
        if let validationError = newConfig.validationError {
            throw MountControllerError.invalidConfiguration(validationError)
        }
        var sanitized = newConfig
        sanitized.volumeName = newConfig.sanitizedVolumeName
        sanitized.sharedDriveID = newConfig.normalizedSharedDriveID
        sanitized.remoteName = config.remoteName
        sanitized.cryptRemoteName = config.cryptRemoteName
        // Credentials and encryption are managed by the Setup Assistant, never by
        // the Settings form.
        sanitized.usesCustomOAuth = config.usesCustomOAuth
        sanitized.clientID = config.clientID
        sanitized.accountEmail = config.accountEmail
        sanitized.useEncryption = config.useEncryption
        sanitized.hasCompletedOnboarding = config.hasCompletedOnboarding

        let rootChanged = sanitized.sharedDriveID != config.sharedDriveID
        let wasMounted = hasMountSession
        let needsRemount = sanitized.mountProfileDiffers(from: config)
        if wasMounted && needsRemount {
            await unmount()
            try Task.checkCancellation()
            guard !hasMountSession else {
                throw MountControllerError.mountFailed("Settings were not changed because the previous volume is still attached or has pending writes. Finish uploads and retry.")
            }
        } else if isMounted && sanitized.bandwidthArgument != config.bandwidthArgument {
            try await rcClient.setBandwidthLimit(sanitized.bandwidthArgument)
            try Task.checkCancellation()
        }
        if rootChanged {
            try await requireSafeDriveRootChange()
            let profile = try await configService.setDriveRoot(
                remoteName: config.remoteName, sharedDriveID: sanitized.sharedDriveID, expectedSharedDriveID: config.sharedDriveID
            )
            sanitized.sharedDriveID = profile.sharedDriveID ?? ""
            pinnedPaths = []
            PinnedPathStore.save(pinnedPaths, to: defaults)
            telemetry.about = nil
            accountGeneration = UUID()
        }
        config = sanitized
        StreamConfigStore.save(config, to: defaults)
        state.volumeName = config.sanitizedVolumeName
        if !wasMounted || needsRemount { state.mountPath = resolvedDefaultMountPath() }
        errorMessage = nil

        if wasMounted && needsRemount {
            let remounted = await mountVolume(allowOwnedConfigurationOperation: true)
            if !remounted {
                throw MountControllerError.mountFailed(
                    state.lastError ?? "Settings were saved, but the volume could not be remounted."
                )
            }
        }
        if enableFinderIntegration {
            await FinderIntegrationService.applyFinderPreferences(showDesktopIcons: config.showDriveOnDesktop)
        }
    }

    private func requireSafeDriveRootChange() async throws {
        guard !hasMountSession else { throw MountControllerError.operationInProgress("Unmount before changing the mount root") }
        if lastPersistedWriteRisk?.requiresExitConsent == true {
            throw MountControllerError.invalidConfiguration("Pending writes to the previous drive could not be ruled out. Mount that drive and finish uploads before changing its root.")
        }
        try paths.prepareFileSystem()
        let cache = try RcloneDriveRootService.prepareCacheDirectory(
            namespace: configService.profile(for: config.remoteName)?.cacheNamespace, root: paths.cacheDirectory
        )
        let observation = await DirtyCacheInspection.inspectUnmountedCache(cacheRoot: cache)
        try Task.checkCancellation()
        guard observation.complete, observation.dirtyFiles == 0 else {
            throw MountControllerError.invalidConfiguration("The previous drive's cache may still contain pending writes. Mount that drive and finish or recover its uploads before changing the mount root.")
        }
    }

    func removeGoogleAccount() async throws {
        try await runConfigurationOperation { try await self.performAccountRemoval() }
    }

    private func performAccountRemoval() async throws {
        if let risk = lastPersistedWriteRisk, risk.state == .pending || risk.state == .blocked {
            if rcloneProcess?.isRunning == true { _ = await refreshWriteSafetyNow() }
            if lastPersistedWriteRisk?.state == .pending || lastPersistedWriteRisk?.state == .blocked {
            throw MountControllerError.invalidConfiguration("Pending cache writes may still require this account. Finish or recover them before removing its credentials.")
            }
        }
        if hasMountSession {
            await unmount()
        }
        try Task.checkCancellation()
        if hasMountSession {
            throw MountControllerError.mountFailed(
                "Unmount the volume before removing the Google account."
            )
        }
        try await configService.removeRemote(named: config.remoteName)
        if configService.remoteExists(config.cryptRemoteName) {
            try? await configService.removeRemote(named: config.cryptRemoteName)
        }
        try? keychain.delete(for: KeychainAccountName.cryptPassword)
        try? keychain.delete(for: KeychainAccountName.cryptSaltPassword)
        try? keychain.delete(for: KeychainAccountName.googleClientSecret)

        config.useEncryption = false
        config.usesCustomOAuth = false
        config.clientID = ""
        config.accountEmail = ""
        config.sharedDriveID = ""
        accountGeneration = UUID()
        config.hasCompletedOnboarding = false
        StreamConfigStore.save(config, to: defaults)
        remoteIsConfigured = false
        accountLabel = nil
        telemetry.about = nil
        state.status = .unmounted
        state.mountedAt = nil
        state.backend = nil
        state.lastError = nil
        errorMessage = nil
        showToast("Google Drive was disconnected.")
    }

    // MARK: Finder / app actions

    func openInFinder() {
        guard isMounted else {
            showToast("Mount Google Drive first.")
            return
        }
        let path = mountPath
        // Do not synchronously stat an unavailable network path on the UI actor.
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func showSidebarHelp() {
        NotificationCenter.default.post(name: .driveStreamShowSidebarHelp, object: nil)
    }

    func openMountFolderForSidebar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: mountPath, isDirectory: true))
    }

    func openVolumeRootInFinder() {
        let url = paths.volumeRootDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.open(url)
    }

    func openLogs() {
        if let log = currentLogURL {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            try? FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(paths.logsDirectory)
        }
    }

    func openConfigFolder() {
        try? paths.prepareFileSystem()
        NSWorkspace.shared.activateFileViewerSelecting([paths.configFile])
    }

    func applyFinderIntegrationNow() {
        guard enableFinderIntegration else { return }
        Task { [weak self] in
            await FinderIntegrationService.applyFinderPreferences(showDesktopIcons: self?.config.showDriveOnDesktop ?? true)
            self?.showToast("Finder preferences updated. Restart Finder if the Desktop icon does not appear.")
        }
    }

    func restartFinder() {
        guard enableFinderIntegration else { return }
        Task { [weak self] in
            await FinderIntegrationService.restartFinder()
            self?.showToast("Finder restarted.")
        }
    }

    func updateFinderServices() {
        guard enableFinderIntegration else { return }
        Task { [weak self] in
            await FinderIntegrationService.updateServicesRegistry()
            self?.showToast("Finder services refreshed.")
        }
    }

    func setShowDriveOnDesktop(_ enabled: Bool) {
        config.showDriveOnDesktop = enabled
        StreamConfigStore.save(config, to: defaults)
        applyFinderIntegrationNow()
    }

    func dismissError() {
        errorMessage = nil
        mountIssue = nil
    }

    func recoverFromMountIssue() {
        guard let issue = mountIssue else { return }
        switch issue.recovery {
        case .retryMount:
            Task {
                if hasMountSession { await unmount() }
                if !hasMountSession { _ = await mount() }
            }
        case .retryUnmount:
            Task { await unmount() }
        case .openSetup:
            presentSetupAssistant()
        case .openSettings:
            presentSettings()
        }
    }

    func presentSetupAssistant() {
        NotificationCenter.default.post(name: .driveStreamShowOnboarding, object: nil)
    }

    func presentSettings() {
        NotificationCenter.default.post(name: .driveStreamShowSettings, object: nil)
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    func copyMountPathToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mountPath, forType: .string)
        showToast("Mount path copied.")
    }

    // MARK: Toast

    private func showToast(_ message: String, duration: TimeInterval = 5) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            self?.toastMessage = nil
        }
    }

    // MARK: Helpers

    private static func generateRCPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
