import Foundation

/// Exact vfs/queue item shape. The queue is read-only evidence, not proof that
/// external applications have closed every writer or Google has durable backups.
struct RcloneUploadQueueItem: Decodable, Equatable, Sendable, Identifiable {
    let id: Int64
    let name: String
    let size: Int64
    let expiry: Double
    let tries: Int
    let delay: Double
    let uploading: Bool

    private enum CodingKeys: String, CodingKey { case id, name, size, expiry, tries, delay, uploading }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int64.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        size = try values.decode(Int64.self, forKey: .size)
        expiry = try values.decode(Double.self, forKey: .expiry)
        tries = try values.decode(Int.self, forKey: .tries)
        delay = try values.decode(Double.self, forKey: .delay)
        uploading = try values.decode(Bool.self, forKey: .uploading)
        guard id > 0, !name.isEmpty, size >= 0, tries >= 0,
              expiry.isFinite, delay.isFinite, delay >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid upload queue item."))
        }
    }
}

struct RcloneUploadQueue: Decodable, Equatable, Sendable {
    let queue: [RcloneUploadQueueItem]
    private enum CodingKeys: String, CodingKey { case queue }

    init(queue: [RcloneUploadQueueItem] = []) { self.queue = queue }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Missing/null is not a known-empty queue. Cache-off/unsupported/malformed
        // replies must never let the app silently approve shutdown.
        queue = try values.decode([RcloneUploadQueueItem].self, forKey: .queue)
        guard Set(queue.map(\.id)).count == queue.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Duplicate upload queue IDs."))
        }
    }
}

struct UploadSafetySnapshot: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case unknown, idleObserved, pending, blocked }
    var state: State = .unknown
    var checkedAt: Date?
    var pendingFiles: Int?
    var pendingBytes: Int64?
    var activeUploads = 0
    var retriedFiles = 0
    var detail = "Pending cloud writes have not been checked."

    var needsAttention: Bool { state == .blocked || state == .unknown }
    var requiresExitConsent: Bool { state != .idleObserved || !isFresh }
    var isFresh: Bool {
        guard let checkedAt else { return false }
        let age = Date().timeIntervalSince(checkedAt)
        return age >= 0 && age < 10
    }

    var title: String {
        switch state {
        case .unknown: return "Cloud-write status unavailable"
        case .idleObserved: return "Nothing queued for upload"
        case .pending: return "Uploads pending"
        case .blocked: return "Cloud writes need attention"
        }
    }

    static func unavailable(_ detail: String) -> UploadSafetySnapshot {
        UploadSafetySnapshot(detail: detail)
    }

    static func assess(queue: RcloneUploadQueue, vfs: RcloneVFSStats, core: RcloneCoreStats,
                       now: Date = Date()) -> UploadSafetySnapshot {
        guard let cache = vfs.diskCache,
              let queued = cache.uploadsQueued, let active = cache.uploadsInProgress,
              let errors = cache.erroredFiles, let outOfSpace = cache.outOfSpace,
              queued >= 0, active >= 0, errors >= 0 else {
            return .unavailable("rclone did not return complete cache/write status. Keep the app running or explicitly confirm an interrupted exit.")
        }
        // fatalError is an optional diagnostic, not evidence of queue completeness.
        // A missing/false flag must not mask a clean queue or, more importantly,
        // prevent explicit cache errors/out-of-space below from being reported.
        // Idle remains an observation: the exit path separately checks dirty cache
        // metadata and asks macOS for a non-forced unmount before stopping rclone.
        let sum = queued.addingReportingOverflow(active)
        let count = max(queue.queue.count, sum.overflow ? Int.max : sum.partialValue)
        var bytes: Int64 = 0
        for item in queue.queue {
            let added = bytes.addingReportingOverflow(item.size)
            bytes = added.overflow ? Int64.max : added.partialValue
        }
        let retried = queue.queue.filter { $0.tries > 1 }.count
        var result = UploadSafetySnapshot(
            state: count == 0 ? .idleObserved : .pending, checkedAt: now,
            pendingFiles: count, pendingBytes: bytes, activeUploads: active,
            retriedFiles: retried,
            detail: count == 0
                ? "No queued uploads were observed. Close other apps writing to the volume before unmounting."
                : "Keep DriveStream running until these writes reach Google Drive. Local cache data must not be deleted."
        )
        if outOfSpace {
            result.state = .blocked
            result.detail = "The local cache reported insufficient space. Free space outside the live cache and retry; do not delete pending cache files."
        } else if errors > 0 || core.fatalError == true {
            result.state = .blocked
            result.detail = "rclone reported cache or fatal transfer errors. Review the private log and retain the cache until required writes are recovered."
        } else if retried > 0 {
            result.detail = "Some uploads are being retried. Keep the app and network available; queued writes remain local until completed."
        }
        return result
    }
}
