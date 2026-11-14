import Foundation

// MARK: - Flexible value decoding

private extension KeyedDecodingContainer {
    func flexibleInt64(_ key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite,
           let exact = Int64(exactly: value) { return exact }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func flexibleInt(_ key: Key) -> Int? {
        guard let value = flexibleInt64(key) else { return nil }
        return Int(value)
    }

    func flexibleDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return Double(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            return parsed?.isFinite == true ? parsed : nil
        }
        return nil
    }

    func flexibleString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    func flexibleBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        return nil
    }
}

// MARK: - About

/// Response from `POST /operations/about`.
struct RcloneAbout: Decodable, Equatable, Sendable {
    var total: Int64?
    var used: Int64?
    var free: Int64?
    var trashed: Int64?
    var other: Int64?
    var objects: Int64?

    init(total: Int64? = nil, used: Int64? = nil, free: Int64? = nil, trashed: Int64? = nil, other: Int64? = nil, objects: Int64? = nil) {
        self.total = total
        self.used = used
        self.free = free
        self.trashed = trashed
        self.other = other
        self.objects = objects
    }

    private enum CodingKeys: String, CodingKey {
        case total, used, free, trashed, other, objects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = container.flexibleInt64(.total)
        used = container.flexibleInt64(.used)
        free = container.flexibleInt64(.free)
        trashed = container.flexibleInt64(.trashed)
        other = container.flexibleInt64(.other)
        objects = container.flexibleInt64(.objects)
    }

    var usedFraction: Double? {
        guard let total, total > 0, let used else { return nil }
        return min(max(Double(used) / Double(total), 0), 1)
    }

    var effectiveTotal: Int64? {
        if let total, total > 0 { return total }
        guard let used, let free, used >= 0, free >= 0 else { return nil }
        let (capacity, overflow) = used.addingReportingOverflow(free)
        guard !overflow, capacity > 0 else { return nil }
        return capacity
    }

    var isEmpty: Bool {
        total == nil && used == nil && free == nil && trashed == nil && other == nil && objects == nil
    }
}

// MARK: - Core stats

/// One active transfer reported by `POST /core/stats`.
struct RcloneTransfer: Decodable, Equatable, Sendable {
    var name: String
    var size: Int64?
    var bytes: Int64?
    var percentage: Int?
    var speed: Double?
    var speedAvg: Double?
    var eta: Double?
    var group: String?
    var startedAt: String?
    var srcFs: String?
    var dstFs: String?

    init() {
        name = "Transfer"
    }

    private enum CodingKeys: String, CodingKey {
        case name, size, bytes, percentage, speed, speedAvg, eta, group, startedAt, srcFs, dstFs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.flexibleString(.name) ?? "Transfer"
        size = container.flexibleInt64(.size)
        bytes = container.flexibleInt64(.bytes)
        percentage = container.flexibleInt(.percentage)
        speed = container.flexibleDouble(.speed)
        speedAvg = container.flexibleDouble(.speedAvg)
        eta = container.flexibleDouble(.eta)
        group = container.flexibleString(.group)
        startedAt = container.flexibleString(.startedAt)
        srcFs = container.flexibleString(.srcFs)
        dstFs = container.flexibleString(.dstFs)
    }
}

/// Response from `POST /core/stats`.
struct RcloneCoreStats: Decodable, Equatable, Sendable {
    var speed: Double?
    var bytes: Int64?
    var totalBytes: Int64?
    var transfers: Int?
    var totalTransfers: Int?
    var elapsedTime: Double?
    var errors: Int?
    var fatalError: Bool?
    var retryError: Bool?
    var transferring: [RcloneTransfer]

    init() {
        transferring = []
    }

    private enum CodingKeys: String, CodingKey {
        case speed, bytes, totalBytes, transfers, totalTransfers
        case elapsedTime, errors, fatalError, retryError, transferring
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speed = container.flexibleDouble(.speed)
        bytes = container.flexibleInt64(.bytes)
        totalBytes = container.flexibleInt64(.totalBytes)
        transfers = container.flexibleInt(.transfers)
        totalTransfers = container.flexibleInt(.totalTransfers)
        elapsedTime = container.flexibleDouble(.elapsedTime)
        errors = container.flexibleInt(.errors)
        fatalError = container.flexibleBool(.fatalError)
        retryError = container.flexibleBool(.retryError)
        transferring = (try? container.decodeIfPresent([RcloneTransfer].self, forKey: .transferring)) ?? []
    }

    var activeTransferCount: Int { transferring.count }
}

// MARK: - VFS stats

struct RcloneDiskCache: Decodable, Equatable, Sendable {
    var path: String?
    var pathMeta: String?
    var bytesUsed: Int64?
    var files: Int?
    var erroredFiles: Int?
    var uploadsInProgress: Int?
    var uploadsQueued: Int?
    var outOfSpace: Bool?
    var hashType: Int?

    private enum CodingKeys: String, CodingKey {
        case path, pathMeta, bytesUsed, files, erroredFiles
        case uploadsInProgress, uploadsQueued, outOfSpace, hashType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = container.flexibleString(.path)
        pathMeta = container.flexibleString(.pathMeta)
        bytesUsed = container.flexibleInt64(.bytesUsed)
        files = container.flexibleInt(.files)
        erroredFiles = container.flexibleInt(.erroredFiles)
        uploadsInProgress = container.flexibleInt(.uploadsInProgress)
        uploadsQueued = container.flexibleInt(.uploadsQueued)
        outOfSpace = container.flexibleBool(.outOfSpace)
        hashType = container.flexibleInt(.hashType)
    }
}

struct RcloneCacheSummary: Decodable, Equatable, Sendable {
    var bytesUsed: Int64?
    var files: Int?
    var uploadsInProgress: Int?
    var uploadsQueued: Int?

    private enum CodingKeys: String, CodingKey {
        case bytesUsed, files, uploadsInProgress, uploadsQueued
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bytesUsed = container.flexibleInt64(.bytesUsed)
        files = container.flexibleInt(.files)
        uploadsInProgress = container.flexibleInt(.uploadsInProgress)
        uploadsQueued = container.flexibleInt(.uploadsQueued)
    }
}

struct RcloneMetadataCache: Decodable, Equatable, Sendable {
    var dirs: Int?
    var files: Int?

    private enum CodingKeys: String, CodingKey { case dirs, files }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dirs = container.flexibleInt(.dirs)
        files = container.flexibleInt(.files)
    }
}

struct RcloneVFSOptions: Decodable, Equatable, Sendable {
    var cacheMaxSize: Int64?
    var cacheMaxAge: Int64?
    var writeBack: Int64?
    var readAhead: Int64?
    var readChunkSize: Int64?
    var readChunkSizeLimit: Int64?

    private enum CodingKeys: String, CodingKey {
        case cacheMaxSize = "CacheMaxSize"
        case cacheMaxAge = "CacheMaxAge"
        case writeBack = "WriteBack"
        case readAhead = "ReadAhead"
        case readChunkSize = "ReadChunkSize"
        case readChunkSizeLimit = "ReadChunkSizeLimit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cacheMaxSize = container.flexibleInt64(.cacheMaxSize)
        cacheMaxAge = container.flexibleInt64(.cacheMaxAge)
        writeBack = container.flexibleInt64(.writeBack)
        readAhead = container.flexibleInt64(.readAhead)
        readChunkSize = container.flexibleInt64(.readChunkSize)
        readChunkSizeLimit = container.flexibleInt64(.readChunkSizeLimit)
    }
}

/// Response from `POST /vfs/stats`.
struct RcloneVFSStats: Decodable, Equatable, Sendable {
    var fs: String?
    var inUse: Int?
    var diskCache: RcloneDiskCache?
    var cache: RcloneCacheSummary?
    var metadataCache: RcloneMetadataCache?
    var opt: RcloneVFSOptions?

    private enum CodingKeys: String, CodingKey {
        case fs, inUse, diskCache, cache, metadataCache, opt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fs = container.flexibleString(.fs)
        inUse = container.flexibleInt(.inUse)
        diskCache = try? container.decodeIfPresent(RcloneDiskCache.self, forKey: .diskCache)
        cache = try? container.decodeIfPresent(RcloneCacheSummary.self, forKey: .cache)
        metadataCache = try? container.decodeIfPresent(RcloneMetadataCache.self, forKey: .metadataCache)
        opt = try? container.decodeIfPresent(RcloneVFSOptions.self, forKey: .opt)
    }

    var cacheBytesUsed: Int64 {
        diskCache?.bytesUsed ?? cache?.bytesUsed ?? 0
    }

    var cachedFileCount: Int {
        diskCache?.files ?? cache?.files ?? 0
    }

    var queuedUploads: Int {
        (diskCache?.uploadsQueued ?? 0) + (diskCache?.uploadsInProgress ?? 0)
    }

    var activeStreams: Int { inUse ?? 0 }
}

// MARK: - Jobs and responses

struct RcloneAsyncJob: Decodable, Equatable, Sendable {
    var jobid: Int?
    var executeId: String?

    private enum CodingKeys: String, CodingKey { case jobid, executeId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobid = container.flexibleInt(.jobid)
        executeId = container.flexibleString(.executeId)
    }
}

struct RcloneJobStatus: Decodable, Equatable, Sendable {
    var id: Int?
    var finished: Bool
    var success: Bool?
    var error: String?
    var duration: Double?

    private enum CodingKeys: String, CodingKey { case id, finished, success, error, duration }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleInt(.id)
        finished = container.flexibleBool(.finished) ?? false
        success = container.flexibleBool(.success)
        error = container.flexibleString(.error)
        duration = container.flexibleDouble(.duration)
    }

    var succeeded: Bool {
        if let success { return success }
        return error?.isEmpty ?? true
    }

    var errorMessage: String? {
        guard let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return error
    }
}

struct RcloneForgetResponse: Decodable, Equatable, Sendable {
    var forgotten: [String]?

    private enum CodingKeys: String, CodingKey { case forgotten }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        forgotten = try? container.decodeIfPresent([String].self, forKey: .forgotten)
    }
}

struct RcloneErrorPayload: Decodable, Equatable, Sendable {
    var error: String?
    var path: String?
    var status: Int?

    private enum CodingKeys: String, CodingKey { case error, path, status }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = container.flexibleString(.error)
        path = container.flexibleString(.path)
        status = container.flexibleInt(.status)
    }
}

// MARK: - UI-friendly transfer model

enum TransferDirection: String, Equatable, Sendable {
    case upload
    case download
    case other

    var title: String {
        switch self {
        case .upload: return "Uploading"
        case .download: return "Streaming"
        case .other: return "Transferring"
        }
    }

    var symbolName: String {
        switch self {
        case .upload: return "arrow.up.circle.fill"
        case .download: return "arrow.down.circle.fill"
        case .other: return "arrow.left.arrow.right.circle.fill"
        }
    }
}

struct TransferItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    let direction: TransferDirection
    let completedBytes: Int64
    let totalBytes: Int64
    let speed: Double
    let eta: TimeInterval?

    init(transfer: RcloneTransfer, remoteNames: [String]) {
        let source = transfer.srcFs ?? ""
        let destination = transfer.dstFs ?? ""
        let sourceIsRemote = TransferItem.isRemoteLocation(source, remoteNames: remoteNames)
        let destinationIsRemote = TransferItem.isRemoteLocation(destination, remoteNames: remoteNames)

        if sourceIsRemote && !destinationIsRemote {
            direction = .download
        } else if destinationIsRemote && !sourceIsRemote {
            direction = .upload
        } else if destinationIsRemote {
            direction = .other
        } else if !sourceIsRemote && destination.isEmpty {
            direction = .upload
        } else {
            direction = .other
        }

        name = (transfer.name as NSString).lastPathComponent.isEmpty ? "Transfer" : (transfer.name as NSString).lastPathComponent
        path = transfer.name
        totalBytes = max(transfer.size ?? 0, 0)
        completedBytes = min(max(transfer.bytes ?? 0, 0), totalBytes > 0 ? totalBytes : Int64.max)
        speed = max(transfer.speed ?? transfer.speedAvg ?? 0, 0)
        eta = transfer.eta
        let stableStart = transfer.startedAt ?? ""
        id = "\(direction.rawValue)|\(transfer.name)|\(stableStart)"
    }

    private static func isRemoteLocation(_ value: String, remoteNames: [String]) -> Bool {
        guard !value.isEmpty else { return false }
        for remote in remoteNames where !remote.isEmpty {
            if value.hasPrefix("\(remote):") { return true }
        }
        guard !value.hasPrefix("/") else { return false }
        guard let colon = value.firstIndex(of: ":") else { return false }
        guard let slash = value.firstIndex(of: "/") else { return true }
        return colon < slash
    }

    var progress: Double {
        if totalBytes > 0 {
            return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
        }
        return 0
    }

    var displaySpeed: String { ByteFormat.speed(speed) }
}

struct TelemetrySnapshot: Equatable, Sendable {
    var about: RcloneAbout?
    var core: RcloneCoreStats?
    var vfs: RcloneVFSStats?
    var cacheBytes: Int64 = 0
    var readBytesPerSecond: Double = 0
    var writeBytesPerSecond: Double = 0
    var activeStreams: Int = 0
    var transfers: [TransferItem] = []
    var lastUpdated: Date = .distantPast

    var totalBytes: Int64? { about?.effectiveTotal }
    var usedBytes: Int64? { about?.used }
    var usedFraction: Double? { about?.usedFraction }
    var cachedFileCount: Int { vfs?.cachedFileCount ?? 0 }
    var queuedUploads: Int { vfs?.queuedUploads ?? 0 }
    var hasAnyActivity: Bool {
        readBytesPerSecond > 1 || writeBytesPerSecond > 1 || !transfers.isEmpty || activeStreams > 0
    }
    var isStale: Bool { Date().timeIntervalSince(lastUpdated) > 15 }
}

// MARK: - Formatting

enum ByteFormat {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return bytes(Double(value))
    }

    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 B" }
        let units: [(String, Double)] = [
            ("PB", 1024.0 * 1024 * 1024 * 1024 * 1024),
            ("TB", 1024.0 * 1024 * 1024 * 1024),
            ("GB", 1024.0 * 1024 * 1024),
            ("MB", 1024.0 * 1024),
            ("KB", 1024.0),
            ("B", 1.0)
        ]
        for (unit, factor) in units {
            if value >= factor || unit == "B" {
                let scaled = value / factor
                if unit == "B" {
                    return "\(Int(scaled.rounded())) B"
                }
                let decimals = scaled < 10 ? 1 : 0
                return String(format: "%.\(decimals)f %@", scaled, unit)
            }
        }
        return "0 B"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 1 else { return "0 B/s" }
        return "\(bytes(bytesPerSecond))/s"
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        let clamped = min(max(fraction, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m \(total % 60)s" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    static func quota(total: Int64?, used: Int64?) -> String {
        let usedText = bytes(used)
        guard let total, total > 0 else {
            return used == nil ? "Quota unavailable" : "\(usedText) used"
        }
        return "\(usedText) of \(bytes(total))"
    }
}
