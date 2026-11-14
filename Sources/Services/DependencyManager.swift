import AppKit
import Combine
import Darwin
import Foundation

// MARK: - Filesystem locations

struct DriveStreamPaths: Sendable {
    let applicationSupportDirectory: URL
    let binDirectory: URL
    let cacheDirectory: URL
    let logsDirectory: URL
    let configFile: URL
    let volumeRootDirectory: URL
    let downloadsDirectory: URL
    let homeDirectory: URL

    init(applicationSupportDirectory: URL? = nil, homeDirectory: URL? = nil) {
        let fileManager = FileManager.default
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let support = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("DriveStream", isDirectory: true)
        self.homeDirectory = home
        self.applicationSupportDirectory = support
        self.binDirectory = support.appendingPathComponent("bin", isDirectory: true)
        self.cacheDirectory = support.appendingPathComponent("cache", isDirectory: true)
        self.logsDirectory = support.appendingPathComponent("logs", isDirectory: true)
        self.configFile = support.appendingPathComponent("rclone.conf")
        self.volumeRootDirectory = home.appendingPathComponent(StreamConfig.homeVolumesDirectoryName, isDirectory: true)
        if let homeDirectory {
            self.downloadsDirectory = homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
        } else {
            self.downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Downloads", isDirectory: true)
        }
    }

    static var current: DriveStreamPaths { DriveStreamPaths() }

    var rcloneBinary: URL { binDirectory.appendingPathComponent("rclone") }

    func prepareFileSystem() throws {
        let fileManager = FileManager.default
        for directory in [applicationSupportDirectory, binDirectory, cacheDirectory, logsDirectory, volumeRootDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            // Tighten directories from older releases too, not only new ones.
            // Cache blocks may contain decrypted file data; logs can name files.
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binDirectory.path)
        let configValues = try? configFile.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard configValues?.isSymbolicLink != true else { throw CocoaError(.fileWriteInvalidFileName) }
        if !fileManager.fileExists(atPath: configFile.path) {
            let header = "# DriveStream private rclone configuration\n# Generated and maintained by DriveStream. Do not commit.\n\n"
            try ServiceFileSafety.atomicWrite(Data(header.utf8), to: configFile)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
    }

    func latestLogFile() -> URL? {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .first
    }
}

// MARK: - Dependency models

struct FuseAvailability: Equatable, Sendable {
    var macFUSEInstalled: Bool
    var fuseTInstalled: Bool

    static let none = FuseAvailability(macFUSEInstalled: false, fuseTInstalled: false)

    var hasAnyFUSE: Bool { macFUSEInstalled || fuseTInstalled }

    var summary: String {
        if macFUSEInstalled && fuseTInstalled { return "macFUSE and FUSE-T are installed." }
        if macFUSEInstalled { return "macFUSE is installed." }
        if fuseTInstalled { return "FUSE-T is installed." }
        return "No FUSE driver installed; the built-in NFS backend will be used."
    }

    var preferredFuseBackend: VolumeBackend? {
        if macFUSEInstalled { return .macFUSE }
        if fuseTInstalled { return .fuseT }
        return nil
    }
}

struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    init?(_ string: String) {
        let pattern = #"v?(\d+)\.(\d+)\.(\d+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: string,
                options: [],
                range: NSRange(string.startIndex..<string.endIndex, in: string)
              ),
              let majorRange = Range(match.range(at: 1), in: string),
              let minorRange = Range(match.range(at: 2), in: string),
              let patchRange = Range(match.range(at: 3), in: string),
              let major = Int(string[majorRange]),
              let minor = Int(string[minorRange]),
              let patch = Int(string[patchRange])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

struct RcloneInstallation: Equatable, Sendable {
    let path: String
    let version: String
    let architecture: String
    let installedAt: Date

    var semanticVersion: SemanticVersion? { SemanticVersion(version) }

    var supportsNFSMount: Bool {
        guard let semanticVersion else { return true }
        return semanticVersion >= SemanticVersion("v1.65.0")!
    }

    var executableURL: URL { URL(fileURLWithPath: path) }

    var displayVersion: String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "rclone" : trimmed
    }
}

enum DependencyPhase: Equatable, Sendable {
    case idle
    case checking
    case downloading(progress: Double)
    case extracting
    case ready
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .checking, .downloading, .extracting: return true
        case .idle, .ready, .failed: return false
        }
    }
}

enum DependencyError: LocalizedError {
    case unsupportedArchitecture(String)
    case invalidDownloadURL(String)
    case archiveExtractionFailed(String)
    case binaryNotFoundInArchive
    case installFailed(String)
    case verificationFailed(String)
    case macFUSENotInstalled
    case macFUSEInstallInProgress
    case checksumMismatch
    case missingChecksum

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let architecture):
            return "Unsupported Mac architecture “\(architecture)”. DriveStream supports Apple Silicon and Intel Macs."
        case .invalidDownloadURL(let url):
            return "The download URL is invalid: \(url)"
        case .archiveExtractionFailed(let message):
            return "Could not extract the rclone archive: \(message)"
        case .binaryNotFoundInArchive:
            return "The rclone archive did not contain the rclone executable."
        case .installFailed(let message):
            return "Could not install rclone: \(message)"
        case .verificationFailed(let message):
            return "The downloaded rclone binary failed verification: \(message)"
        case .macFUSENotInstalled:
            return "macFUSE is not installed."
        case .macFUSEInstallInProgress:
            return "A macFUSE download is already in progress."
        case .checksumMismatch:
            return "The dependency checksum did not match. The download was discarded."
        case .missingChecksum:
            return "The selected dependency did not have an exact official SHA-256 checksum."
        }
    }
}

// MARK: - DependencyManager

@MainActor
final class DependencyManager: ObservableObject {
    static let shared = DependencyManager()

    let paths: DriveStreamPaths

    @Published private(set) var phase: DependencyPhase = .idle
    @Published private(set) var installation: RcloneInstallation?
    @Published private(set) var fuseAvailability: FuseAvailability = .none
    @Published private(set) var lastError: String?
    @Published private(set) var macFUSEProgress: Double?

    private var prepareTask: Task<Bool, Never>?
    private var helpCache: [String: String] = [:]
    private var helpCacheGeneration = 0

    init(paths: DriveStreamPaths = .current) {
        self.paths = paths
        try? paths.prepareFileSystem()
        refreshFuseAvailability()
        refreshLocalInstallation()
    }

    var isRcloneReady: Bool {
        guard let installation else { return false }
        if case .failed = phase { return false }
        return FileManager.default.isExecutableFile(atPath: installation.path)
    }

    var supportsNFSMount: Bool {
        installation?.supportsNFSMount ?? true
    }

    var macFUSEInstallationInProgress: Bool { macFUSEProgress != nil }

    var rcloneBinaryURL: URL { paths.rcloneBinary }

    // MARK: Preparation

    /// Downloads the official rclone binary if needed and verifies the installation.
    /// Concurrent calls share a single preparation task.
    func prepare(forceReinstall: Bool = false) async -> Bool {
        if let prepareTask {
            return await withTaskCancellationHandler {
                await prepareTask.value
            } onCancel: { prepareTask.cancel() }
        }
        let task = Task<Bool, Never> { @MainActor [weak self] in
            guard let self else { return false }
            do {
                try Task.checkCancellation()
                try self.paths.prepareFileSystem()
                self.refreshFuseAvailability()
                if !forceReinstall,
                   let existing = self.installation,
                   FileManager.default.isExecutableFile(atPath: existing.path) {
                    do {
                        let verified = try await self.verifyInstallation(at: URL(fileURLWithPath: existing.path))
                        self.installation = verified
                        self.phase = .ready
                        self.lastError = nil
                        return true
                    } catch {
                        if error is CancellationError { throw error }
                        NSLog("[DriveStream] Existing rclone failed verification; reinstalling. \(error.localizedDescription)")
                    }
                }
                self.phase = .checking
                self.lastError = nil
                let installed = try await self.downloadAndInstallRclone()
                self.installation = installed
                self.helpCache.removeAll()
                self.helpCacheGeneration += 1
                self.phase = .ready
                self.lastError = nil
                return true
            } catch {
                if error is CancellationError {
                    self.phase = .idle
                    self.lastError = nil
                    return false
                }
                let message = error.localizedDescription
                self.phase = .failed(message)
                self.lastError = message
                return false
            }
        }
        prepareTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        prepareTask = nil
        return result
    }

    /// Cancels the shared preparation worker; shutdown can then join its callers.
    func cancelPreparation() {
        prepareTask?.cancel()
    }

    func refreshLocalInstallation() {
        guard FileManager.default.isExecutableFile(atPath: paths.rcloneBinary.path) else {
            installation = nil
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: paths.rcloneBinary.path)
        let modified = attributes?[.modificationDate] as? Date ?? Date()
        installation = RcloneInstallation(
            path: paths.rcloneBinary.path,
            version: installation?.version ?? "Detected",
            architecture: installation?.architecture ?? Self.compileTimeArchitecture,
            installedAt: modified
        )
        if phase == .idle {
            phase = .ready
        }
    }

    // MARK: FUSE detection

    @discardableResult
    func refreshFuseAvailability() -> FuseAvailability {
        let fileManager = FileManager.default
        let macFUSE = fileManager.fileExists(atPath: "/Library/Filesystems/macfuse.fs")
        let fuseT = fileManager.fileExists(atPath: "/Library/Filesystems/fuse-t.fs")
        let availability = FuseAvailability(macFUSEInstalled: macFUSE, fuseTInstalled: fuseT)
        fuseAvailability = availability
        return availability
    }

    // MARK: Help flags

    /// Fetches (and caches) `rclone <subcommand> --help`. MountController uses this
    /// to check actual option definitions and never pass unknown Finder flags.
    func commandHelp(for subcommand: String) async -> String {
        if let cached = helpCache[subcommand] { return cached }
        guard FileManager.default.isExecutableFile(atPath: paths.rcloneBinary.path) else { return "" }
        let generation = helpCacheGeneration
        let result = try? await CommandRunner.run(
            executable: paths.rcloneBinary.path,
            arguments: ["--config", paths.configFile.path, subcommand, "--help"],
            timeout: 20
        )
        let help = result?.combinedOutput ?? ""
        if !Task.isCancelled && generation == helpCacheGeneration { helpCache[subcommand] = help }
        return help
    }

    // MARK: Download and install rclone

    private func downloadAndInstallRclone() async throws -> RcloneInstallation {
        try Task.checkCancellation()
        let architecture = try await currentArchitecture()

        let fileManager = FileManager.default
        let temporaryRoot = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-rclone-")
        defer { ServiceFileSafety.removeTemporaryDirectory(temporaryRoot, prefix: "DriveStream-rclone-") }

        let versionData = try await DependencyArchiveSafety.fetchData(
            from: RcloneDownloads.versionURL, maximumBytes: 1024
        )
        let release = try RcloneDownloads.Release(
            versionText: String(decoding: versionData, as: UTF8.self), architecture: architecture
        )
        let checksumData = try await DependencyArchiveSafety.fetchData(from: release.checksumURL)
        guard let expectedHash = DependencyArchiveSafety.checksum(
            in: String(decoding: checksumData, as: UTF8.self), for: release.archiveName
        ) else { throw DependencyError.missingChecksum }

        let archiveURL = temporaryRoot.appendingPathComponent(release.archiveName)
        phase = .downloading(progress: 0)
        let downloader = FileDownloader()
        _ = try await downloader.download(from: release.downloadURL, to: archiveURL) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .downloading = self.phase {
                    self.phase = .downloading(progress: progress)
                }
            }
        }

        try await Self.verifyArchiveChecksum(at: archiveURL, expectedHash: expectedHash)
        let archiveWorker = Task.detached(priority: .utility) {
            try DependencyArchiveSafety.rcloneMember(
                in: archiveURL, version: release.version, architecture: release.architecture
            )
        }
        let member = try await withTaskCancellationHandler {
            try await archiveWorker.value
        } onCancel: { archiveWorker.cancel() }
        try Task.checkCancellation()

        phase = .extracting
        let extractionDirectory = temporaryRoot.appendingPathComponent("expanded", isDirectory: true)
        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        do {
            _ = try await CommandRunner.run(
                executable: "/usr/bin/unzip",
                arguments: ["-o", "-q", archiveURL.path, member, "-d", extractionDirectory.path],
                timeout: 180
            )
        } catch {
            if error is CancellationError { throw error }
            throw DependencyError.archiveExtractionFailed(error.localizedDescription)
        }

        let extractedBinary = extractionDirectory.appendingPathComponent(member)
        let binaryValues = try extractedBinary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard binaryValues.isRegularFile == true, binaryValues.isSymbolicLink != true,
              extractedBinary.resolvingSymlinksInPath().standardizedFileURL == extractedBinary.standardizedFileURL else {
            throw DependencyError.binaryNotFoundInArchive
        }

        let binDirectory = paths.binDirectory.resolvingSymlinksInPath().standardizedFileURL
        let stagingURL = binDirectory.appendingPathComponent(".rclone-\(UUID().uuidString)")
        defer { ServiceFileSafety.removeStaging(stagingURL, parent: binDirectory, prefix: ".rclone-") }
        do {
            try fileManager.copyItem(at: extractedBinary, to: stagingURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingURL.path)
        } catch {
            if error is CancellationError { throw error }
            throw DependencyError.installFailed(error.localizedDescription)
        }

        _ = try? await CommandRunner.run(
            executable: "/usr/bin/xattr",
            arguments: ["-c", stagingURL.path],
            timeout: 20
        )

        let verified = try await verifyInstallation(at: stagingURL)
        do {
            try Task.checkCancellation()
            try ServiceFileSafety.atomicReplace(stagingURL, destination: binDirectory.appendingPathComponent("rclone"))
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.rcloneBinary.path)
        } catch {
            if error is CancellationError { throw error }
            throw DependencyError.installFailed(error.localizedDescription)
        }

        let attributes = try? fileManager.attributesOfItem(atPath: paths.rcloneBinary.path)
        let modified = attributes?[.modificationDate] as? Date ?? Date()
        let finalInstallation = RcloneInstallation(
            path: paths.rcloneBinary.path,
            version: verified.version,
            architecture: verified.architecture,
            installedAt: modified
        )
        NSLog("[DriveStream] Installed \(finalInstallation.version) at \(finalInstallation.path)")
        return finalInstallation
    }

    /// Keep this fail-closed gate ahead of archive inspection, extraction and execution.
    nonisolated static func verifyArchiveChecksum(at archiveURL: URL, expectedHash: String) async throws {
        let actualHash = try await DependencyArchiveSafety.sha256(of: archiveURL)
        guard actualHash == expectedHash else { throw DependencyError.checksumMismatch }
    }

    private func verifyInstallation(at url: URL) async throws -> RcloneInstallation {
        let result: CommandResult
        do {
            result = try await CommandRunner.run(executable: url.path, arguments: ["version"], timeout: 30)
        } catch {
            if error is CancellationError { throw error }
            throw DependencyError.verificationFailed(error.localizedDescription)
        }
        let versionLine = result.standardOutput
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.lowercased().hasPrefix("rclone v") })
            ?? result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SemanticVersion(versionLine) != nil else {
            throw DependencyError.verificationFailed("Unrecognized version output.")
        }

        let help: CommandResult
        do {
            // `help flags` intentionally omits backend/VFS options; `mount --help`
            // is the reliable way to prove this build can mount with a VFS cache.
            help = try await CommandRunner.run(executable: url.path, arguments: ["mount", "--help"], timeout: 30)
        } catch {
            if error is CancellationError { throw error }
            throw DependencyError.verificationFailed(error.localizedDescription)
        }
        guard help.combinedOutput.contains("--vfs-cache-mode"),
              help.combinedOutput.contains("--vfs-cache-max-size") else {
            throw DependencyError.verificationFailed(
                "This rclone build does not include mount/VFS support. DriveStream only uses the official static build."
            )
        }

        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date ?? Date()
        return RcloneInstallation(
            path: url.path,
            version: versionLine,
            architecture: try await currentArchitecture(),
            installedAt: modified
        )
    }

    private func currentArchitecture() async throws -> String {
        // Check the hardware, not just the current process architecture. This keeps
        // the rclone helper native arm64 even if DriveStream itself is launched
        // under Rosetta on an Apple Silicon Mac.
        try Task.checkCancellation()
        if Self.isAppleSilicon { return "arm64" }

        if let result = try? await CommandRunner.run(executable: "/usr/bin/uname", arguments: ["-m"], timeout: 10) {
            let machine = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if machine.hasPrefix("arm64") { return "arm64" }
            if machine.hasPrefix("x86_64") { return "amd64" }
            throw DependencyError.unsupportedArchitecture(machine)
        }
        try Task.checkCancellation()
        return Self.compileTimeArchitecture
    }

    /// Apple Silicon reports `hw.optional.arm64 = 1` even when the current process
    /// is translated by Rosetta.
    nonisolated static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    nonisolated private static var compileTimeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    // MARK: macFUSE

    /// Downloads the latest official macFUSE disk image, verifies its published
    /// SHA-256 checksum, and opens the installer. Installation itself requires the
    /// user to approve the system extension and enter an administrator password.
    func installOrUpdateMacFUSE() async throws -> URL {
        try Task.checkCancellation()
        guard macFUSEProgress == nil else { throw DependencyError.macFUSEInstallInProgress }
        macFUSEProgress = 0
        defer { macFUSEProgress = nil }

        struct GitHubRelease: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadURL: URL

                enum CodingKeys: String, CodingKey {
                    case name
                    case browserDownloadURL = "browser_download_url"
                }
            }

            let tagName: String
            let assets: [Asset]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case assets
            }
        }

        guard let apiURL = URL(string: "https://api.github.com/repos/macfuse/macfuse/releases/latest") else {
            throw DependencyError.invalidDownloadURL("https://api.github.com/repos/macfuse/macfuse/releases/latest")
        }
        let releaseData = try await DependencyArchiveSafety.fetchData(from: apiURL)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: releaseData)
        guard let diskImageAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw DependencyError.macFUSENotInstalled
        }
        guard let checksumAsset = release.assets.first(where: {
            $0.name == diskImageAsset.name.replacingOccurrences(of: ".dmg", with: ".sha256")
        }) else {
            throw DependencyError.missingChecksum
        }

        let fileManager = FileManager.default
        guard DependencyArchiveSafety.safeMemberName(diskImageAsset.name),
              !diskImageAsset.name.contains("/"),
              diskImageAsset.browserDownloadURL.scheme == "https",
              diskImageAsset.browserDownloadURL.host == "github.com",
              diskImageAsset.browserDownloadURL.path.hasPrefix("/macfuse/macfuse/releases/download/"),
              checksumAsset.browserDownloadURL.scheme == "https",
              checksumAsset.browserDownloadURL.host == "github.com",
              checksumAsset.browserDownloadURL.path.hasPrefix("/macfuse/macfuse/releases/download/") else {
            throw DependencyError.invalidDownloadURL("Untrusted macFUSE release asset.")
        }
        let temporaryRoot = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-macfuse-")
        defer { ServiceFileSafety.removeTemporaryDirectory(temporaryRoot, prefix: "DriveStream-macfuse-") }

        let downloader = FileDownloader()
        let downloadedURL = temporaryRoot.appendingPathComponent(diskImageAsset.name)
        _ = try await downloader.download(from: diskImageAsset.browserDownloadURL, to: downloadedURL) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.macFUSEProgress != nil else { return }
                self.macFUSEProgress = progress * 0.9
            }
        }

        let checksumData = try await DependencyArchiveSafety.fetchData(from: checksumAsset.browserDownloadURL)
        guard let expected = DependencyArchiveSafety.checksum(
            in: String(decoding: checksumData, as: UTF8.self), for: diskImageAsset.name
        ) else { throw DependencyError.missingChecksum }
        let actual = try await DependencyArchiveSafety.sha256(of: downloadedURL)
        guard actual == expected else { throw DependencyError.checksumMismatch }

        try fileManager.createDirectory(at: paths.downloadsDirectory, withIntermediateDirectories: true)
        let destination = paths.downloadsDirectory.appendingPathComponent(diskImageAsset.name)
        // Do not replace an existing user Downloads file, even with the same name.
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw DependencyError.installFailed("An installer with this name already exists in Downloads.")
        }
        try Task.checkCancellation()
        try fileManager.copyItem(at: downloadedURL, to: destination)
        macFUSEProgress = 1

        NSWorkspace.shared.open(destination)
        NSApp.activate(ignoringOtherApps: true)
        return destination
    }

    func openMacFUSEWebsite() {
        guard let url = URL(string: "https://macfuse.github.io/") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealRcloneBinaryInFinder() {
        guard FileManager.default.fileExists(atPath: paths.rcloneBinary.path) else {
            NSWorkspace.shared.open(paths.binDirectory)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([paths.rcloneBinary])
    }

}
