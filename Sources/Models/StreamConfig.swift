import Foundation

// MARK: - Mount preferences

/// How DriveStream chooses the filesystem driver used to present Google Drive.
enum MountBackendPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case macFUSE
    case nfs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Automatic (Recommended)"
        case .macFUSE: return "macFUSE"
        case .nfs: return "Built-in NFS"
        }
    }

    var summary: String {
        switch self {
        case .auto:
            return "Prefers macFUSE or FUSE-T when available, then falls back to rclone's dependency-free NFS backend."
        case .macFUSE:
            return "Uses the installed macFUSE or FUSE-T integration; driver approval and actual FSKit/kernel mode depend on the system."
        case .nfs:
            return "Uses rclone's built-in NFSv3 server. No kernel extension, no Recovery Mode, no external dependency."
        }
    }

    var symbolName: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .macFUSE: return "externaldrive.connected.to.line.below"
        case .nfs: return "network"
        }
    }
}

/// Where the mount point is created.
enum MountLocationPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case home
    case volumes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .home: return "Home folder (always available)"
        case .volumes: return "/Volumes (when permitted)"
        }
    }

    var summary: String {
        switch self {
        case .home:
            return "Mounts at ~/DriveStreamVolumes/<Volume Name>. Reliable for every user account."
        case .volumes:
            return "Mounts at /Volumes/<Volume Name> when that directory is writable, otherwise falls back to your home folder."
        }
    }
}

/// The concrete backend selected for a mount.
enum VolumeBackend: String, Codable, CaseIterable, Sendable {
    case macFUSE
    case fuseT
    case nfs

    var displayName: String {
        switch self {
        case .macFUSE: return "macFUSE"
        case .fuseT: return "FUSE-T"
        case .nfs: return "Built-in NFS"
        }
    }

    var shortName: String {
        switch self {
        case .macFUSE: return "macFUSE"
        case .fuseT: return "FUSE-T"
        case .nfs: return "NFS"
        }
    }

    var mountSubcommand: String {
        self == .nfs ? "nfsmount" : "mount"
    }

    var usesFUSE: Bool { self != .nfs }

    var technicalSummary: String {
        switch self {
        case .macFUSE:
            return "rclone mount · macFUSE integration; actual driver mode is system-dependent"
        case .fuseT:
            return "rclone mount · FUSE-T user-space filesystem over a local NFS bridge"
        case .nfs:
            return "rclone nfsmount · rclone's embedded NFSv3 server, no kernel extension"
        }
    }
}

// MARK: - Configuration model

/// Every user-changeable setting. The struct is persisted as JSON in UserDefaults.
/// OAuth secrets and crypt passwords are deliberately *not* stored here; they live in
/// the macOS Keychain and in DriveStream's private rclone.conf (mode 0600).
struct StreamConfig: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    static let defaultVolumeName = "Google Drive"
    static let defaultRemoteName = "gdrive"
    static let defaultCryptRemoteName = "gdrive-crypt"
    static let defaultCacheMaxSize = "10G"
    static let defaultCacheMaxAge = "1h"
    static let homeVolumesDirectoryName = "DriveStreamVolumes"

    var schemaVersion: Int = StreamConfig.currentSchemaVersion
    var volumeName: String = StreamConfig.defaultVolumeName
    var remoteName: String = StreamConfig.defaultRemoteName
    var cryptRemoteName: String = StreamConfig.defaultCryptRemoteName
    /// Empty selects My Drive. The private config is authoritative after a restart.
    var sharedDriveID: String = ""

    /// Whether all reads and writes go through the `rclone crypt` remote.
    var useEncryption: Bool = false
    /// Whether the user supplied a personal Google Cloud OAuth client.
    var usesCustomOAuth: Bool = false
    /// Public OAuth client identifier. The matching secret is stored in the Keychain.
    var clientID: String = ""
    /// Cached account label (usually the Google account e-mail) for display only.
    var accountEmail: String = ""

    /// rclone size suffix, for example "10G" or "25G".
    var cacheMaxSize: String = StreamConfig.defaultCacheMaxSize
    /// rclone duration, for example "1h", "30m", or "24h".
    var cacheMaxAge: String = StreamConfig.defaultCacheMaxAge

    var mountBackend: MountBackendPreference = .auto
    var mountLocation: MountLocationPreference = .home
    /// Absolute path. Empty means DriveStream chooses the path automatically.
    var customMountPath: String = ""

    var autoMountOnLaunch: Bool = true
    var suppressSpotlightIndexing: Bool = true
    var showDriveOnDesktop: Bool = true
    var hasCompletedOnboarding: Bool = false
    var performanceMode: PerformanceMode = .automatic
    /// Zero means automatic; otherwise 1...4 bounded file readers.
    var pinConcurrency: Int = 0
    /// Zero means unlimited; rclone receives explicit binary MiB/s suffixes.
    var uploadLimitMiB: Int = 0
    var downloadLimitMiB: Int = 0
    var recoverMountAfterWake: Bool = true

    init() {}

    // MARK: Computed values

    /// Finder-visible volume name, stripped of path separators and control characters.
    var sanitizedVolumeName: String {
        let trimmed = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = ""
        for scalar in trimmed.unicodeScalars {
            switch scalar {
            case "/", ":", "\\":
                cleaned.append("-")
            case "\n", "\r", "\t", "\0":
                cleaned.append(" ")
            default:
                cleaned.unicodeScalars.append(scalar)
            }
        }
        cleaned = cleaned
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return StreamConfig.defaultVolumeName }
        if cleaned == "." || cleaned == ".." { return StreamConfig.defaultVolumeName }
        return String(cleaned.prefix(64))
    }

    /// The remote actually mounted: either the encrypted view or the raw Drive remote.
    var effectiveRemoteName: String {
        useEncryption ? cryptRemoteName : remoteName
    }

    var effectiveRemoteSpecifier: String { "\(effectiveRemoteName):" }
    var quotaRemoteSpecifier: String { "\(remoteName):" }
    var normalizedSharedDriveID: String { sharedDriveID.trimmingCharacters(in: .whitespacesAndNewlines) }

    var normalizedCacheMaxSize: String {
        SizeParser.canonicalString(from: cacheMaxSize) ?? cacheMaxSize.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedCacheMaxAge: String {
        cacheMaxAge.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var cacheCapBytes: Int64 {
        SizeParser.bytes(from: cacheMaxSize) ?? 10 * 1024 * 1024 * 1024
    }

    var cacheMaxAgeSeconds: TimeInterval {
        DurationParser.seconds(from: cacheMaxAge) ?? 3600
    }

    var homeVolumesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(StreamConfig.homeVolumesDirectoryName, isDirectory: true)
    }

    var defaultHomeMountPath: String {
        homeVolumesRoot.appendingPathComponent(sanitizedVolumeName, isDirectory: true).path
    }

    /// Resolves the mount point. `/Volumes` is only used when the process can create
    /// entries there; otherwise the home-folder location is used automatically.
    func resolvedMountPath(volumesWritable: Bool) -> String {
        let custom = customMountPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return (custom as NSString).expandingTildeInPath
        }
        if mountLocation == .volumes, volumesWritable {
            return "/Volumes/\(sanitizedVolumeName)"
        }
        return defaultHomeMountPath
    }

    /// rclone's `SizeSuffix` parser treats a bare number as KiB. Always give
    /// byte-valued flags an explicit `B` suffix.
    static func rcloneByteSizeArgument(_ bytes: Int64) -> String {
        "\(max(bytes, 0))B"
    }

    var performancePolicy: PerformancePolicy {
        PerformancePolicy.resolve(mode: performanceMode, pinOverride: pinConcurrency)
    }

    var bandwidthArgument: String {
        if uploadLimitMiB == 0 && downloadLimitMiB == 0 { return "off" }
        let upload = uploadLimitMiB == 0 ? "off" : "\(uploadLimitMiB)M"
        let download = downloadLimitMiB == 0 ? "off" : "\(downloadLimitMiB)M"
        return upload + ":" + download
    }

    func mountProfileDiffers(from other: StreamConfig) -> Bool {
        sanitizedVolumeName != other.sanitizedVolumeName || mountBackend != other.mountBackend
            || mountLocation != other.mountLocation || customMountPath != other.customMountPath
            || normalizedCacheMaxSize != other.normalizedCacheMaxSize
            || normalizedCacheMaxAge != other.normalizedCacheMaxAge || performanceMode != other.performanceMode
            || normalizedSharedDriveID != other.normalizedSharedDriveID
    }

    var validationError: String? {
        if !normalizedSharedDriveID.isEmpty && !GoogleSharedDrive.validID(normalizedSharedDriveID) {
            return DriveRootError.invalidID.localizedDescription
        }
        if !(0...4).contains(pinConcurrency) { return "Cache warming must use automatic or 1–4 parallel readers." }
        if !(0...10000).contains(uploadLimitMiB) || !(0...10000).contains(downloadLimitMiB) {
            return "Bandwidth limits must be 0 (unlimited) through 10000 MiB/s."
        }
        let trimmedVolumeName = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedVolumeName.isEmpty {
            return "The volume name must not be empty."
        }
        if trimmedVolumeName.count > 64 {
            return "The volume name must be 64 characters or fewer."
        }
        if trimmedVolumeName.contains("/") || trimmedVolumeName.contains(":") {
            return "The volume name must not contain “/” or “:”."
        }
        if remoteName.isEmpty || remoteName.contains(":") || remoteName.contains("/") {
            return "The rclone remote name is invalid."
        }
        if cryptRemoteName.isEmpty || cryptRemoteName.contains(":") || cryptRemoteName.contains("/") {
            return "The encrypted remote name is invalid."
        }
        guard let cacheBytes = SizeParser.bytes(from: cacheMaxSize) else {
            return "The cache limit must look like 10G, 25G, or 512M."
        }
        let minimumCache = Int64(512 * 1024 * 1024)
        let maximumCache = Int64(10) * 1024 * 1024 * 1024 * 1024
        if cacheBytes < minimumCache {
            return "The cache limit must be at least 512 MB."
        }
        if cacheBytes > maximumCache {
            return "The cache limit must be 10 TB or less."
        }
        guard let age = DurationParser.seconds(from: cacheMaxAge) else {
            return "The cache age must look like 30m, 1h, or 24h."
        }
        if age < 60 {
            return "The cache age must be at least 1 minute."
        }
        if age > 30 * 24 * 60 * 60 {
            return "The cache age must be 30 days or less."
        }
        let custom = customMountPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            if !expanded.hasPrefix("/") {
                return "The custom mount path must be an absolute path."
            }
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            if standardized == "/" {
                return "DriveStream cannot use the filesystem root as a mount point."
            }
            let forbiddenPrefixes = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private"]
            if forbiddenPrefixes.contains(where: { standardized == $0 || standardized.hasPrefix($0 + "/") }) {
                return "Choose a mount point inside your home folder or /Volumes."
            }
            if standardized == "/Volumes" {
                return "Choose a folder inside /Volumes, not /Volumes itself."
            }
        }
        return nil
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case volumeName
        case remoteName
        case cryptRemoteName
        case sharedDriveID
        case useEncryption
        case usesCustomOAuth
        case clientID
        case accountEmail
        case cacheMaxSize
        case cacheMaxAge
        case mountBackend
        case mountLocation
        case customMountPath
        case autoMountOnLaunch
        case suppressSpotlightIndexing
        case showDriveOnDesktop
        case hasCompletedOnboarding
        case performanceMode, pinConcurrency, uploadLimitMiB, downloadLimitMiB, recoverMountAfterWake
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StreamConfig()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? defaults.schemaVersion
        volumeName = try container.decodeIfPresent(String.self, forKey: .volumeName) ?? defaults.volumeName
        remoteName = try container.decodeIfPresent(String.self, forKey: .remoteName) ?? defaults.remoteName
        cryptRemoteName = try container.decodeIfPresent(String.self, forKey: .cryptRemoteName) ?? defaults.cryptRemoteName
        sharedDriveID = try container.decodeIfPresent(String.self, forKey: .sharedDriveID) ?? defaults.sharedDriveID
        useEncryption = try container.decodeIfPresent(Bool.self, forKey: .useEncryption) ?? defaults.useEncryption
        usesCustomOAuth = try container.decodeIfPresent(Bool.self, forKey: .usesCustomOAuth) ?? defaults.usesCustomOAuth
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID) ?? defaults.clientID
        accountEmail = try container.decodeIfPresent(String.self, forKey: .accountEmail) ?? defaults.accountEmail
        cacheMaxSize = try container.decodeIfPresent(String.self, forKey: .cacheMaxSize) ?? defaults.cacheMaxSize
        cacheMaxAge = try container.decodeIfPresent(String.self, forKey: .cacheMaxAge) ?? defaults.cacheMaxAge
        mountBackend = try container.decodeIfPresent(MountBackendPreference.self, forKey: .mountBackend) ?? defaults.mountBackend
        mountLocation = try container.decodeIfPresent(MountLocationPreference.self, forKey: .mountLocation) ?? defaults.mountLocation
        customMountPath = try container.decodeIfPresent(String.self, forKey: .customMountPath) ?? defaults.customMountPath
        autoMountOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoMountOnLaunch) ?? defaults.autoMountOnLaunch
        suppressSpotlightIndexing = try container.decodeIfPresent(Bool.self, forKey: .suppressSpotlightIndexing) ?? defaults.suppressSpotlightIndexing
        showDriveOnDesktop = try container.decodeIfPresent(Bool.self, forKey: .showDriveOnDesktop) ?? defaults.showDriveOnDesktop
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? defaults.hasCompletedOnboarding
        performanceMode = try container.decodeIfPresent(PerformanceMode.self, forKey: .performanceMode) ?? defaults.performanceMode
        pinConcurrency = try container.decodeIfPresent(Int.self, forKey: .pinConcurrency) ?? defaults.pinConcurrency
        uploadLimitMiB = try container.decodeIfPresent(Int.self, forKey: .uploadLimitMiB) ?? defaults.uploadLimitMiB
        downloadLimitMiB = try container.decodeIfPresent(Int.self, forKey: .downloadLimitMiB) ?? defaults.downloadLimitMiB
        recoverMountAfterWake = try container.decodeIfPresent(Bool.self, forKey: .recoverMountAfterWake) ?? defaults.recoverMountAfterWake
    }
}

// MARK: - Persistence

enum StreamConfigStore {
    static let storageKey = "DriveStream.streamConfiguration.v1"

    static func load(from defaults: UserDefaults = .standard) -> StreamConfig {
        guard let data = defaults.data(forKey: storageKey) else { return StreamConfig() }
        do {
            return try JSONDecoder().decode(StreamConfig.self, from: data)
        } catch {
            NSLog("[DriveStream] Failed to decode saved configuration: \(error.localizedDescription)")
            return StreamConfig()
        }
    }

    static func save(_ configuration: StreamConfig, to defaults: UserDefaults = .standard) {
        do {
            let data = try JSONEncoder().encode(configuration)
            defaults.set(data, forKey: storageKey)
        } catch {
            NSLog("[DriveStream] Failed to encode configuration: \(error.localizedDescription)")
        }
    }

    static func reset(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

enum PinnedPathStore {
    static let storageKey = "DriveStream.pinnedPaths.v1"

    static func load(from defaults: UserDefaults = .standard) -> Set<String> {
        guard let array = defaults.stringArray(forKey: storageKey) else { return [] }
        return Set(array.filter { !$0.isEmpty })
    }

    static func save(_ paths: Set<String>, to defaults: UserDefaults = .standard) {
        defaults.set(Array(paths).sorted(), forKey: storageKey)
    }
}

// MARK: - Size and duration parsing

/// rclone option-name compatibility helpers.
enum RcloneFlagCompatibility {
    /// Canonical rclone spellings. There is no hyphen after "no".
    static let appleMetadataFlags = ["--noappledouble", "--noapplexattr"]

    /// Include only flags that the selected rclone subcommand advertises as
    /// actual option definitions. Passing an unknown flag aborts the mount.
    static func supportedAppleMetadataFlags(in help: String) -> [String] {
        guard !help.isEmpty else { return [] }
        let optionLines = help
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return appleMetadataFlags.filter { flag in
            optionLines.contains { line in
                line == flag
                    || line.hasPrefix(flag + " ")
                    || line.hasPrefix(flag + "\t")
            }
        }
    }
}

enum SizeParser {
    private static let sizeExpression = try? NSRegularExpression(
        pattern: #"^\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?)(?:I?B)?\s*$"#,
        options: [.caseInsensitive]
    )

    private static let unitPowers: [String: Int] = ["": 0, "K": 1, "M": 2, "G": 3, "T": 4]

    /// Parses rclone-style binary size suffixes (K/M/G/T, optional iB) into bytes.
    static func bytes(from raw: String) -> Int64? {
        guard let expression = sizeExpression else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[numberRange])
        else { return nil }
        let unit = String(text[unitRange]).uppercased()
        guard let power = unitPowers[unit] else { return nil }
        let multiplier = pow(1024.0, Double(power))
        let result = value * multiplier
        guard result.isFinite, let bytes = Int64(exactly: result.rounded()), bytes > 0 else { return nil }
        return bytes
    }

    /// Returns a compact rclone-compatible spelling, preferring exact binary units.
    static func canonicalString(from raw: String) -> String? {
        guard let parsed = bytes(from: raw) else { return nil }
        let units: [(suffix: String, factor: Double)] = [
            ("T", 1024.0 * 1024 * 1024 * 1024),
            ("G", 1024.0 * 1024 * 1024),
            ("M", 1024.0 * 1024),
            ("K", 1024.0)
        ]
        for (suffix, factor) in units {
            let value = Double(parsed) / factor
            if value >= 1, value.rounded() == value {
                return "\(Int(value))\(suffix)"
            }
        }
        // A bare rclone SizeSuffix is KiB, not bytes. Non-unit-aligned values must
        // keep an explicit B suffix or the configured cap becomes 1024x too large.
        return "\(parsed)B"
    }
}

enum DurationParser {
    private static let durationExpression = try? NSRegularExpression(
        pattern: #"^\s*([0-9]+(?:\.[0-9]+)?)\s*(s|m|h|d|w)\s*$"#,
        options: [.caseInsensitive]
    )

    private static let unitSeconds: [String: Double] = [
        "s": 1,
        "m": 60,
        "h": 3600,
        "d": 86_400,
        "w": 604_800
    ]

    static func seconds(from raw: String) -> TimeInterval? {
        guard let expression = durationExpression else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[numberRange])
        else { return nil }
        let unit = String(text[unitRange]).lowercased()
        guard let multiplier = unitSeconds[unit] else { return nil }
        let result = value * multiplier
        return result.isFinite && result > 0 ? result : nil
    }
}
