import Foundation

// MARK: - Mount status

enum MountStatus: String, Codable, CaseIterable, Sendable {
    case unmounted
    case preparing
    case mounting
    case indexing
    case mounted
    case unmounting
    case failed

    var title: String {
        switch self {
        case .unmounted: return "Unmounted"
        case .preparing: return "Preparing…"
        case .mounting: return "Mounting…"
        case .indexing: return "Indexing in RAM"
        case .mounted: return "Mounted"
        case .unmounting: return "Unmounting…"
        case .failed: return "Needs Attention"
        }
    }

    var detailTitle: String {
        switch self {
        case .unmounted: return "Google Drive is offline"
        case .preparing: return "Checking the filesystem driver"
        case .mounting: return "Starting the rclone VFS"
        case .indexing: return "Pre-warming the directory tree"
        case .mounted: return "Ready for Finder"
        case .unmounting: return "Flushing writes and detaching"
        case .failed: return "The volume is not available"
        }
    }

    var symbolName: String {
        switch self {
        case .unmounted: return "externaldrive"
        case .preparing, .mounting: return "hourglass"
        case .indexing: return "bolt.circle"
        case .mounted: return "externaldrive.fill"
        case .unmounting: return "eject.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var isMounted: Bool {
        switch self {
        case .indexing, .mounted, .unmounting: return true
        case .unmounted, .preparing, .mounting, .failed: return false
        }
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .mounting, .unmounting: return true
        case .unmounted, .indexing, .mounted, .failed: return false
        }
    }

    var isFailure: Bool { self == .failed }
}

// MARK: - Mount state

struct MountState: Equatable, Sendable {
    var status: MountStatus = .unmounted
    var backend: VolumeBackend?
    var volumeName: String = StreamConfig.defaultVolumeName
    var mountPath: String = ""
    var mountedAt: Date?
    var mountStartedAt: Date?
    var lastError: String?
    /// Retained after a failed detach so Retry Unmount remains available.
    var volumeStillAttached = false

    var isMounted: Bool { status.isMounted }
    var isBusy: Bool { status.isBusy }

    var mountedDuration: TimeInterval? {
        guard let mountedAt else { return nil }
        return Date().timeIntervalSince(mountedAt)
    }

    static func unmounted(volumeName: String, mountPath: String) -> MountState {
        MountState(status: .unmounted, volumeName: volumeName, mountPath: mountPath)
    }
}

// MARK: - Background pinning

/// Lightweight, user-visible progress for the Finder "Pin Offline" service.
struct PinProgress: Equatable, Sendable {
    enum Phase: String, Sendable {
        case scanning
        case caching
        case finishing
    }

    var phase: Phase = .scanning
    var currentPath: String = ""
    var completedFiles: Int = 0
    var completedBytes: Int64 = 0
    var failedFiles: Int = 0
    var startedAt: Date = Date()

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
}

struct PinResult: Equatable, Sendable {
    var filesRead: Int
    var bytesRead: Int64
    var failedFiles: Int
    var pinnedPaths: Set<String>
    var duration: TimeInterval
}

struct EvictionResult: Equatable, Sendable {
    var evictedPaths: [String]
    var failures: [String]
}

// MARK: - Errors

enum MountControllerError: LocalizedError {
    case notConnected
    case invalidConfiguration(String)
    case dependencyUnavailable(String)
    case alreadyMounted
    case notMounted
    case operationInProgress(String)
    case pathOutsideVolume(String)
    case backendUnavailable(String)
    case mountFailed(String)
    case encryptionNotConfigured
    case cryptPasswordMissing
    case encryptionPasswordTooShort
    case googleAccountMissing

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Google Drive is not connected yet."
        case .invalidConfiguration(let message):
            return message
        case .dependencyUnavailable(let message):
            return message
        case .alreadyMounted:
            return "DriveStream is already mounted."
        case .notMounted:
            return "DriveStream is not mounted."
        case .operationInProgress(let operation):
            return "\(operation) is already in progress. Please wait for it to finish."
        case .pathOutsideVolume(let path):
            return "“\(path)” is not inside the mounted DriveStream volume."
        case .backendUnavailable(let message):
            return message
        case .mountFailed(let message):
            return message
        case .encryptionNotConfigured:
            return "Encryption is enabled but the encrypted remote is not configured. Open the Setup Assistant to finish configuring it."
        case .cryptPasswordMissing:
            return "The encryption password is missing from the Keychain. Open the Setup Assistant to re-enter it."
        case .encryptionPasswordTooShort:
            return "Use an encryption password with at least 8 characters."
        case .googleAccountMissing:
            return "The Google Drive remote is missing. Open the Setup Assistant to connect your account."
        }
    }
}
