import Foundation

/// The fixed Finder/VFS profile, separated from process ownership and UI state.
/// Inputs are snapshots; no credentials or config are persisted by this builder.
enum MountArgumentsBuilder {
    static func build(
        config: StreamConfig,
        paths: DriveStreamPaths,
        backend: VolumeBackend,
        help: String,
        mountPath: String,
        logURL: URL,
        diskSpaceTotal: Int64?,
        username: String,
        password: String,
        cacheDirectory: URL? = nil
    ) -> [String] {
        let command = backend.mountSubcommand
        let policy = config.performancePolicy
        // These are the exact rclone option names: no hyphen after "no". They are
        // supported by rclone mount and by current rclone nfsmount builds, but we
        // never assume that: append each flag only when the selected command's own
        // --help output lists it. An unknown flag would abort the mount instantly.
        let appleMetadataFlags = RcloneFlagCompatibility.supportedAppleMetadataFlags(in: help)

        var arguments: [String] = [
            "--config", paths.configFile.path,
            command,
            config.effectiveRemoteSpecifier,
            mountPath,

            // Remote control used by the menu bar, Finder services, and telemetry.
            "--rc",
            "--rc-addr", RCServerEndpoint.listenAddress,
            "--rc-user", username,
            "--rc-job-expire-duration", "30m",
            "--rc-job-expire-interval", "30s",

            // RAM metadata pre-warm and Finder responsiveness.
            "--dir-cache-time", "9999h",
            "--poll-interval", "15s",
            "--attr-timeout", "1h",

            // Google Drive API burst pacing for Finder/QuickLook storms.
            "--drive-pacer-min-sleep", "10ms",
            "--drive-pacer-burst", "200",
            "--drive-chunk-size", policy.driveChunkSize,
            "--transfers", String(policy.transfers),
            "--checkers", "16",

            // Full VFS cache gives NVMe-speed writes and byte-range streaming.
            "--vfs-cache-mode", "full",
            "--vfs-write-back", "5s",
            "--vfs-read-chunk-size", "16M",
            "--vfs-read-chunk-size-limit", "256M",
            "--vfs-read-ahead", "64M",
            "--vfs-read-wait", "20ms",
            "--buffer-size", policy.bufferSize,
            "--vfs-cache-max-size", config.normalizedCacheMaxSize,
            "--vfs-cache-max-age", config.normalizedCacheMaxAge,
            "--vfs-cache-poll-interval", "10s",
            "--cache-dir", (cacheDirectory ?? paths.cacheDirectory).path,

            // Present a first-class Finder volume with a native icon.
            "--volname", config.sanitizedVolumeName,
            "--log-file", logURL.path,
            "--log-level", "INFO",
            "--log-format", "date,time",
            "--stats", "0"
        ]

        // Apple metadata flags are appended only when this exact rclone command
        // advertises them. They are canonical names without an extra hyphen.
        arguments += appleMetadataFlags
        if config.bandwidthArgument != "off" {
            arguments += ["--bwlimit", config.bandwidthArgument]
        }
        if backend == .nfs {
            // Darwin's soft NFS client returns an error rather than hanging Finder
            // forever if its local helper dies. Keep it browsable; never nobrowse.
            // Keep the platform's normal retry/timeout policy: aggressive small
            // values can turn a legitimate uncached cloud delay into an I/O error.
            arguments += ["--option", "soft"]
        }

        if let diskSpaceTotal, diskSpaceTotal > 0 {
            // rclone parses a bare SizeSuffix value as KiB. Use an explicit byte
            // suffix so Finder reports the real Google Drive quota, not 1024× it.
            arguments += ["--vfs-disk-space-total-size", StreamConfig.rcloneByteSizeArgument(diskSpaceTotal)]
        }
        return arguments
    }
}
