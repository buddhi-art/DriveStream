import Foundation

/// Owns read-only display polling. Fresh exit checks and the write-risk ledger
/// deliberately remain with MountController, never with a display snapshot.
@MainActor
final class MountTelemetryCoordinator {
    struct Session: Sendable {
        let client: RcloneRCClient
        let remote: String
        let quotaRemote: String
        let remoteNames: [String]
    }

    enum Update: Sendable {
        case activity(TelemetrySnapshot, TelemetryReading)
        case activityUnavailable(warning: String?)
        case quota(RcloneAbout)
        case quotaUnavailable(warning: String)
        case retrying(Bool)
    }

    private var session: Session?
    private var onUpdate: (@MainActor (Update) -> Void)?
    private var snapshot = TelemetrySnapshot()
    private var pollTask: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var pollID: UUID?
    private var quotaRequestID: UUID?
    private var recovery = TelemetryRecoveryState()
    private var quotaFailures = 0
    private var successfulPolls = 0
    private var networkAvailable = true
    private var estimator = TelemetryRateEstimator()

    deinit {
        pollTask?.cancel()
        quotaTask?.cancel()
    }

    func start(
        session: Session,
        initialSnapshot: TelemetrySnapshot,
        networkAvailable: Bool,
        onUpdate: @escaping @MainActor (Update) -> Void
    ) {
        stop()
        self.session = session
        self.snapshot = initialSnapshot
        self.networkAvailable = networkAvailable
        self.onUpdate = onUpdate
        recovery.recordSuccess()
        quotaFailures = 0
        beginPolling(forceQuota: false)
    }

    /// A new helper resets sampling history; sleep/wake of the same helper does not.
    func resetSessionMetrics() {
        estimator = TelemetryRateEstimator()
        successfulPolls = 0
    }

    func setNetworkAvailable(_ available: Bool) {
        networkAvailable = available
        if !available { cancelQuota() }
    }

    /// Replace only activity polling: an already-running quota read stays singleflight.
    func refreshNow() {
        guard session != nil else { return }
        beginPolling(forceQuota: true)
    }

    func requestQuotaRefresh() {
        guard quotaTask == nil, pollID != nil, networkAvailable, let session else { return }
        let generation = sessionID
        let requestID = UUID()
        quotaRequestID = requestID
        quotaTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // An old completion must never release a replacement request's slot.
                if self.sessionID == generation, self.quotaRequestID == requestID {
                    self.quotaTask = nil
                    self.quotaRequestID = nil
                }
            }
            do {
                let about = try await TelemetryService.quota(client: session.client, remote: session.quotaRemote)
                try Task.checkCancellation()
                guard self.sessionID == generation, self.quotaRequestID == requestID else { return }
                self.snapshot.about = about
                self.quotaFailures = 0
                self.onUpdate?(.quota(about))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.sessionID == generation,
                      self.quotaRequestID == requestID else { return }
                self.quotaFailures += 1
                if self.quotaFailures >= TelemetryRecoveryState.warningThreshold {
                    self.onUpdate?(.quotaUnavailable(warning: "Google Drive quota could not be refreshed. The last reported capacity is shown; live file activity can continue."))
                }
            }
        }
    }

    func stop() {
        sessionID = UUID()
        pollID = nil
        pollTask?.cancel()
        pollTask = nil
        cancelQuota()
        // Keep the session description for Retry Now after a failed wake probe.
        // Its weak controller callback is only used by newly identified requests.
    }

    func resetActivity(from currentSnapshot: TelemetrySnapshot) -> TelemetrySnapshot {
        snapshot = TelemetrySnapshot(about: currentSnapshot.about)
        estimator = TelemetryRateEstimator()
        recovery.recordSuccess()
        quotaFailures = 0
        return snapshot
    }

    private func cancelQuota() {
        quotaRequestID = nil
        quotaTask?.cancel()
        quotaTask = nil
    }

    private func beginPolling(forceQuota: Bool) {
        guard session != nil else { return }
        pollTask?.cancel()
        let generation = sessionID
        let requestID = UUID()
        pollID = requestID
        pollTask = Task { [weak self] in
            var includeQuota = forceQuota
            if forceQuota, self?.isCurrentPoll(generation, requestID) == true {
                self?.onUpdate?(.retrying(true))
            }
            // Do not retain the coordinator across the long-lived sleep/backoff.
            while !Task.isCancelled {
                guard let interval = await self?.poll(
                    forceQuota: includeQuota, generation: generation, requestID: requestID
                ) else { return }
                if includeQuota, self?.isCurrentPoll(generation, requestID) == true {
                    self?.onUpdate?(.retrying(false))
                }
                includeQuota = false
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { return }
            }
        }
    }

    private func isCurrentPoll(_ generation: UUID, _ requestID: UUID) -> Bool {
        !Task.isCancelled && sessionID == generation && pollID == requestID
    }

    private func poll(forceQuota: Bool, generation: UUID, requestID: UUID) async -> TimeInterval? {
        guard isCurrentPoll(generation, requestID), let session else { return nil }
        let reading: TelemetryReading
        do {
            reading = try await TelemetryService.read(client: session.client, remote: session.remote)
            try Task.checkCancellation()
        } catch is CancellationError {
            return nil
        } catch {
            guard isCurrentPoll(generation, requestID) else { return nil }
            let transient = (error as? RcloneRCError)?.isTransient == true
            recovery.recordFailure(isTransient: transient)
            let warning: String? = recovery.shouldWarn
                ? (transient
                    ? "Live activity is temporarily unavailable. Last good readings are shown; DriveStream will retry automatically."
                    : "Live activity cannot be read from rclone. Check the connection or retry; the mounted volume is not being changed.")
                : nil
            // Neither a failed sample nor a quota-only update resets activity or
            // advances its timestamp. The controller keeps the last good readings.
            onUpdate?(.activityUnavailable(warning: warning))
            return isCurrentPoll(generation, requestID) ? recovery.nextPollInterval : nil
        }
        guard isCurrentPoll(generation, requestID) else { return nil }
        recovery.recordSuccess()
        estimator.apply(reading, to: &snapshot, remoteNames: session.remoteNames)
        successfulPolls += 1
        if forceQuota || successfulPolls % 5 == 0 { requestQuotaRefresh() }
        onUpdate?(.activity(snapshot, reading))
        return isCurrentPoll(generation, requestID) ? recovery.nextPollInterval : nil
    }
}

/// Display-rate estimation only; these inferred speeds never authorize an exit.
private struct TelemetryRateEstimator {
    private var lastCacheSampleBytes: Int64 = -1
    private var lastCacheSampleDate = Date()

    mutating func apply(_ reading: TelemetryReading, to telemetry: inout TelemetrySnapshot, remoteNames: [String]) {
        let core = reading.core
        let vfs = reading.vfs
        telemetry.core = core
        telemetry.vfs = vfs
        telemetry.cacheBytes = vfs.cacheBytesUsed
        let items = core.transferring.map {
            TransferItem(transfer: $0, remoteNames: remoteNames)
        }
        let uploads = items.filter { $0.direction == .upload }
        let downloads = items.filter { $0.direction == .download }
        let uploadSpeed = uploads.reduce(0.0) { $0 + $1.speed }
        let downloadSpeed = downloads.reduce(0.0) { $0 + $1.speed }

        let cacheBytes = vfs.cacheBytesUsed
        let now = Date()
        var cacheGrowth = 0.0
        if lastCacheSampleBytes >= 0 {
            let elapsed = max(now.timeIntervalSince(lastCacheSampleDate), 0.5)
            cacheGrowth = max(0, Double(cacheBytes - lastCacheSampleBytes) / elapsed)
        }
        lastCacheSampleBytes = cacheBytes
        lastCacheSampleDate = now

        let readSample = downloadSpeed > 1
            ? downloadSpeed
            : (uploadSpeed > 1 ? 0 : cacheGrowth)
        let writeSample = uploadSpeed > 1
            ? uploadSpeed
            : (uploads.isEmpty ? 0 : (core.speed ?? 0))

        let smoothing = 0.55
        var smoothedRead = telemetry.readBytesPerSecond * smoothing + readSample * (1 - smoothing)
        if readSample == 0 {
            smoothedRead = max(0, smoothedRead - 512 * 1024)
            if smoothedRead < 1_024 { smoothedRead = 0 }
        }
        telemetry.readBytesPerSecond = smoothedRead.isFinite ? max(smoothedRead, 0) : 0
        telemetry.writeBytesPerSecond = writeSample.isFinite ? max(writeSample, 0) : 0
        telemetry.activeStreams = max(vfs.activeStreams, downloads.count)
        telemetry.transfers = items.sorted {
            if $0.direction == $1.direction { return $0.progress > $1.progress }
            if $0.direction == .upload { return true }
            if $1.direction == .upload { return false }
            return $0.progress > $1.progress
        }
        telemetry.lastUpdated = now
    }
}
