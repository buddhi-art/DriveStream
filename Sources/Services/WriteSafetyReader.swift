import Foundation

/// Dependency boundary for fresh exit checks. Test readers do not need a real
/// mounted filesystem, Google account or OS-global application instance.
protocol WriteSafetyReading: Sendable {
    func read(client: RcloneRCClient, remote: String) async throws -> UploadSafetySnapshot
}

struct RemoteWriteSafetyReader: WriteSafetyReading {
    let cacheRoot: URL

    func read(client: RcloneRCClient, remote: String) async throws -> UploadSafetySnapshot {
        let policy = RCRetryPolicy()
        async let core = policy.perform { try await client.coreStats() }
        async let vfs = policy.perform { try await client.vfsStats(remote: remote) }
        async let queue = policy.perform { try await client.uploadQueue() }
        let cache = try await vfs
        var safety = try await UploadSafetySnapshot.assess(queue: queue, vfs: cache, core: core)
        let dirty = await DirtyCacheInspection.inspect(metadataPath: cache.diskCache?.pathMeta, cacheRoot: cacheRoot)
        try Task.checkCancellation()
        if !dirty.complete {
            safety.state = .unknown
            safety.detail = dirty.detail + " Close writers and explicitly confirm any interrupted exit."
        } else if dirty.dirtyFiles > 0 {
            if safety.state != .blocked { safety.state = .pending }
            safety.pendingFiles = max(safety.pendingFiles ?? 0, dirty.dirtyFiles)
            safety.detail = "Modified local cache files remain, including writes not yet queued. Close writers and keep the app running until they upload."
        }
        safety.checkedAt = Date()
        return safety
    }
}
