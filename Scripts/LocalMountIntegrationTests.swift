import AppKit
import Darwin
import Foundation

@main
@MainActor
struct LocalMountIntegrationTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "LiveMount", code: 1, userInfo: [NSLocalizedDescriptionKey: "Supply a verified rclone path and its SHA-256."])
        }
        let binary = URL(fileURLWithPath: CommandLine.arguments[1])
        let expectedHash = CommandLine.arguments[2].lowercased()
        let hash = try await DependencyArchiveSafety.sha256(of: binary)
        guard hash == expectedHash, expectedHash.count == 64 else {
            throw NSError(domain: "LiveMount", code: 2, userInfo: [NSLocalizedDescriptionKey: "rclone checksum did not match."])
        }
        let root = URL(fileURLWithPath: "/tmp/DriveStream-live-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let home = root.appendingPathComponent("home", isDirectory: true)
        let cloud = root.appendingPathComponent("remote", isDirectory: true)
        let mount = root.appendingPathComponent("volume", isDirectory: true)
        for folder in [home, cloud, mount] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let paths = DriveStreamPaths(applicationSupportDirectory: root.appendingPathComponent("support"), homeDirectory: home)
        try paths.prepareFileSystem()
        try FileManager.default.copyItem(at: binary, to: paths.rcloneBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.rcloneBinary.path)
        try ServiceFileSafety.atomicWrite(Data("[fixture]\ntype = alias\nremote = \(cloud.path)\n".utf8), to: paths.configFile)
        let suite = "DriveStream.live-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var config = StreamConfig()
        config.remoteName = "fixture"
        config.volumeName = "DriveStream Live Test"
        config.customMountPath = mount.path
        config.mountBackend = .nfs
        config.autoMountOnLaunch = false
        let keychain = KeychainHelper(service: suite)
        let client = RcloneRCClient()
        let controller = MountController(dependencyManager: DependencyManager(paths: paths),
            configService: RcloneConfigService(paths: paths, keychain: keychain), rcClient: client,
            paths: paths, keychain: keychain, configuration: config, initialPins: [], defaults: defaults,
            enableFinderIntegration: false, backendCandidates: [.nfs], profileIsUsable: { $0?.type == "alias" })
        var checks = 0
        func expect(_ condition: Bool, _ name: String) throws {
            guard condition else { throw NSError(domain: "LiveMount", code: 3, userInfo: [NSLocalizedDescriptionKey: name]) }
            checks += 1; Self.report("PASS: " + name)
        }
        do {
            let original = Data(repeating: 0x5a, count: 1024 * 1024)
            try original.write(to: cloud.appendingPathComponent("source.bin"))
            try expect(await controller.mount(), "actual rclone NFS mount reaches controller readiness")
            let pid = try await client.processID()
            try expect(pid > 0 && client.baseURL?.port != nil, "authenticated PID and OS-assigned RC port verified")
            let canonical = mount.resolvingSymlinksInPath().path
            let visible = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
            try expect(visible.contains { $0.resolvingSymlinksInPath().path == canonical }, "mounted volume is registered with macOS and not hidden from browsing")
            try expect(try Data(contentsOf: mount.appendingPathComponent("source.bin")) == original, "real NFS cached read matches fixture bytes")
            try original.write(to: mount.appendingPathComponent("upload.bin"))
            try await waitUntil("closed writes reach the real local remote") {
                (try? Data(contentsOf: cloud.appendingPathComponent("upload.bin"))) == original
            }
            try await waitUntil("fresh queue and dirty metadata become idle") {
                let safety = await controller.refreshWriteSafetyNow()
                return safety.state == .idleObserved && safety.isFresh
            }
            let writerURL = mount.appendingPathComponent("held-writer.bin")
            _ = FileManager.default.createFile(atPath: writerURL.path, contents: nil)
            let writer = try FileHandle(forWritingTo: writerURL)
            try writer.write(contentsOf: original)
            let pending = await controller.refreshWriteSafetyNow()
            try expect(pending.requiresExitConsent, "held dirty writer is not silently certified by an empty upload queue")
            await controller.unmount()
            try expect(controller.hasMountSession, "ordinary unmount retains helper while modified/open data remains")
            try writer.synchronize()
            try writer.close()
            try await waitUntil("held writer finishes after close") {
                let remoteMatches = (try? Data(contentsOf: cloud.appendingPathComponent("held-writer.bin"))) == original
                let safety = await controller.refreshWriteSafetyNow()
                return remoteMatches && safety.state == .idleObserved
            }
            controller.handleDeviceLifecycle(.network(.unavailable))
            controller.handleDeviceLifecycle(.willSleep)
            try expect(controller.hasMountSession, "offline/sleep event preserves attached filesystem")
            controller.handleDeviceLifecycle(.didWake)
            controller.handleDeviceLifecycle(.network(.available))
            try await waitUntil("wake recovery returns to the same live PID") {
                let actualPID = try? await client.processID()
                return !controller.isSleeping && !controller.isBusy && actualPID == pid
            }
            try expect(try Data(contentsOf: mount.appendingPathComponent("source.bin")) == original, "cached read remains valid after simulated lifecycle transitions")
            var limits = controller.config
            limits.uploadLimitMiB = 2
            limits.downloadLimitMiB = 4
            try await controller.applySettings(limits)
            try expect(try await client.processID() == pid, "bandwidth-only settings do not restart the mount process")
            await controller.unmount()
            let remainsMounted = await MountTable.isActive(path: mount.path)
            try expect(!controller.hasMountSession && !remainsMounted, "normal final unmount leaves no live volume")
            defaults.removePersistentDomain(forName: suite)
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let resolved = buffer.withUnsafeMutableBufferPointer { storage -> String? in
                guard realpath(root.path, storage.baseAddress) != nil, let base = storage.baseAddress else { return nil }
                return String(cString: base)
            }
            guard let resolved, resolved.hasPrefix("/private/tmp/DriveStream-live-"),
                  !resolved.dropFirst("/private/tmp/".count).contains("/"),
                  root.lastPathComponent.hasPrefix("DriveStream-live-") else { throw CocoaError(.fileWriteInvalidFileName) }
            try FileManager.default.removeItem(at: URL(fileURLWithPath: resolved))
            Self.report("ALL LIVE LOCAL MOUNT CHECKS PASSED (\(checks) direct assertions plus bounded transfer/recovery checks)")
        } catch {
            await controller.unmount(allowPendingUploads: true)
            defaults.removePersistentDomain(forName: suite)
            Self.report("Fixture retained for diagnostics: \(root.path)")
            Self.report("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func report(_ text: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }

    static func waitUntil(_ name: String, condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if await condition() { report("PASS: " + name); return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw NSError(domain: "LiveMount", code: 4, userInfo: [NSLocalizedDescriptionKey: name])
    }
}
