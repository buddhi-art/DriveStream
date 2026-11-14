import Foundation

/// Read-only discovery and verified, atomic root changes. Helpers see only private
/// snapshots, so token refresh cannot race the live mount's configuration writer.
struct RcloneDriveRootService {
    static let cacheNamespaceKey = "drivestream_cache_namespace"
    let paths: DriveStreamPaths

    func sharedDrives(remoteName: String) async throws -> [GoogleSharedDrive] {
        do {
            let original = try snapshot(remoteName: remoteName)
            let directory = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-drive-list-")
            defer { ServiceFileSafety.removeTemporaryDirectory(directory, prefix: "DriveStream-drive-list-") }
            let candidate = directory.appendingPathComponent("rclone.conf")
            // Discovery must work even when a formerly selected drive is inaccessible.
            let data = try RclonePrivateConfig.updating(original, section: remoteName, options: [
                "team_drive": nil, "root_folder_id": nil, "shared_with_me": nil
            ])
            try ServiceFileSafety.createPrivateFile(candidate, data: data)
            let result = try await CommandRunner.run(executable: paths.rcloneBinary.path,
                arguments: ["--config", candidate.path, "backend", "drives", remoteName + ":"], timeout: 45)
            try Task.checkCancellation()
            return try GoogleSharedDrive.decodeList(result.standardOutput)
        } catch is CancellationError { throw CancellationError() }
        catch let error as DriveRootError { throw error }
        catch { throw DriveRootError.listingFailed }
    }

    func setDriveRoot(remoteName: String, sharedDriveID: String, expectedSharedDriveID: String) async throws -> RcloneRemoteProfile {
        guard sharedDriveID.isEmpty || GoogleSharedDrive.validID(sharedDriveID) else { throw DriveRootError.invalidID }
        do {
            let original = try snapshot(remoteName: remoteName)
            guard let oldProfile = RcloneConfigService.profile(in: original, for: remoteName),
                  (oldProfile.sharedDriveID ?? "") == expectedSharedDriveID else { throw DriveRootError.configurationChanged }
            let directory = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-drive-root-")
            defer { ServiceFileSafety.removeTemporaryDirectory(directory, prefix: "DriveStream-drive-root-") }
            let candidate = directory.appendingPathComponent("rclone.conf")
            // A fresh cache identity is committed WITH the root, not in UserDefaults.
            // Even a crash between config publication and UI persistence cannot replay
            // the old root's cached blocks/writes into a different drive. Old data stays
            // on disk; changing roots is not an implicit cache deletion operation.
            let namespace = UUID().uuidString.lowercased()
            let data = try RclonePrivateConfig.updating(original, section: remoteName, options: [
                "team_drive": sharedDriveID.isEmpty ? nil : sharedDriveID,
                "root_folder_id": nil, "shared_with_me": nil,
                Self.cacheNamespaceKey: namespace
            ])
            try ServiceFileSafety.createPrivateFile(candidate, data: data)
            // Shared Drives may not implement quota/about. A shallow directory list
            // verifies read access without writing anything to Google Drive.
            try await verifyAccess(remoteName: remoteName, configFile: candidate)
            try Task.checkCancellation()
            let verified = try readPrivateConfig(candidate)
            guard let profile = RcloneConfigService.profile(in: verified, for: remoteName),
                  profile.isDrive, profile.hasToken,
                  (profile.sharedDriveID ?? "") == sharedDriveID,
                  profile.cacheNamespace == namespace else { throw DriveRootError.verificationFailed }
            guard try readPrivateConfig(paths.configFile) == original else { throw DriveRootError.configurationChanged }
            try Task.checkCancellation()
            try ServiceFileSafety.atomicWrite(verified, to: paths.configFile)
            // No suspension/cancellation point after commit: the caller must publish
            // the corresponding UI state, even if cancellation arrived during rename.
            return profile
        } catch is CancellationError { throw CancellationError() }
        catch let error as DriveRootError { throw error }
        catch { throw DriveRootError.verificationFailed }
    }

    func verifyAccess(remoteName: String, configFile: URL) async throws {
        _ = try await CommandRunner.run(executable: paths.rcloneBinary.path,
            arguments: ["--config", configFile.path, "lsf", remoteName + ":", "--dirs-only", "--max-depth", "1"], timeout: 45)
    }

    private func snapshot(remoteName: String) throws -> Data {
        try Task.checkCancellation()
        guard RcloneConfigService.validRemoteName(remoteName) else { throw DriveRootError.notConnected }
        guard FileManager.default.isExecutableFile(atPath: paths.rcloneBinary.path) else { throw RcloneConfigError.binaryMissing }
        try paths.prepareFileSystem()
        let original = try readPrivateConfig(paths.configFile)
        guard let profile = RcloneConfigService.profile(in: original, for: remoteName),
              profile.isDrive, profile.hasToken else { throw DriveRootError.notConnected }
        return original
    }

    private func readPrivateConfig(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DriveRootError.privateConfigUnavailable }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = 4 * 1024 * 1024
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw DriveRootError.privateConfigUnavailable }
        return data
    }

    static func cacheDirectory(namespace: String?, root: URL) throws -> URL {
        guard let namespace, !namespace.isEmpty else { return root }
        guard let identifier = UUID(uuidString: namespace),
              identifier.uuidString.lowercased() == namespace else { throw DriveRootError.privateConfigUnavailable }
        return root.appendingPathComponent("mount-roots", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    static func prepareCacheDirectory(namespace: String?, root: URL) throws -> URL {
        let directory = try cacheDirectory(namespace: namespace, root: root)
        guard directory != root else { return root }
        for item in [directory.deletingLastPathComponent(), directory] {
            try ServiceFileSafety.requireChild(item, of: item.deletingLastPathComponent())
            do {
                try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // Reusing the namespace parent is normal; verify its type below.
            } catch { throw DriveRootError.privateConfigUnavailable }
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw DriveRootError.privateConfigUnavailable }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: item.path)
        }
        return directory
    }
}
