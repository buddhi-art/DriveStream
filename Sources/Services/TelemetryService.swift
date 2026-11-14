import Foundation

/// Bounded exponential retry for read-only RC requests. Mounting, refresh jobs,
/// eviction and configuration writes deliberately do not use this policy.
struct RCRetryPolicy: Sendable, Equatable {
    var maximumAttempts = 3
    var initialDelay: TimeInterval = 0.5
    var maximumDelay: TimeInterval = 4

    func delay(afterFailedAttempt attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 16)
        return min(maximumDelay, initialDelay * pow(2, Double(exponent)))
    }

    func perform<Value: Sendable>(
        sleep: @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(for: .seconds(delay))
        },
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let attempts = max(1, maximumAttempts)
        for attempt in 1...attempts {
            try Task.checkCancellation()
            do {
                let value = try await operation()
                try Task.checkCancellation()
                return value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard let rcError = error as? RcloneRCError,
                      rcError.isTransient, attempt < attempts else { throw error }
                try await sleep(delay(afterFailedAttempt: attempt))
            }
        }
        // The range always runs once, returning or throwing on its final attempt.
        throw CancellationError()
    }
}

struct TelemetryReading: Sendable {
    let core: RcloneCoreStats
    let vfs: RcloneVFSStats
}

enum TelemetryService {
    static func read(client: RcloneRCClient, remote: String) async throws -> TelemetryReading {
        let policy = RCRetryPolicy()
        async let core = policy.perform { try await client.coreStats() }
        async let vfs = policy.perform { try await client.vfsStats(remote: remote) }
        return try await TelemetryReading(core: core, vfs: vfs)
    }

    static func quota(client: RcloneRCClient, remote: String) async throws -> RcloneAbout {
        try await RCRetryPolicy().perform { try await client.about(remote: remote) }
    }

    /// Read-only fresh assessment. This is deliberately separate from display
    /// telemetry so a stale screen can never authorize destructive shutdown.
    static func writeStatus(client: RcloneRCClient, remote: String) async throws -> UploadSafetySnapshot {
        let policy = RCRetryPolicy()
        async let core = policy.perform { try await client.coreStats() }
        async let vfs = policy.perform { try await client.vfsStats(remote: remote) }
        async let queue = policy.perform { try await client.uploadQueue() }
        return try await UploadSafetySnapshot.assess(queue: queue, vfs: vfs, core: core)
    }
}

/// Separate long-lived poll-loop backoff from the short request retry. A healthy
/// mount samples every two seconds; a failing endpoint never spins in a tight loop.
struct TelemetryRecoveryState: Sendable, Equatable {
    private(set) var consecutiveFailures = 0
    private(set) var lastFailureWasTransient = true
    static let warningThreshold = 3
    static let normalPollInterval: TimeInterval = 2
    static let maximumPollInterval: TimeInterval = 30

    var shouldWarn: Bool {
        consecutiveFailures >= Self.warningThreshold
            || (consecutiveFailures > 0 && !lastFailureWasTransient)
    }

    var nextPollInterval: TimeInterval {
        guard consecutiveFailures > 0 else { return Self.normalPollInterval }
        return min(Self.maximumPollInterval, Self.normalPollInterval * pow(2, Double(min(consecutiveFailures, 4))))
    }

    mutating func recordFailure(isTransient: Bool) {
        consecutiveFailures = min(consecutiveFailures + 1, 1000)
        lastFailureWasTransient = isTransient
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        lastFailureWasTransient = true
    }
}
