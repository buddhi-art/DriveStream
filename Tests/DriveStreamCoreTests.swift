import Foundation
import XCTest

/// Hostless tests compile the real models/services without launching the menu-bar
/// app, registering a login item, changing Finder, or accessing a real account.
final class DriveStreamCoreTests: XCTestCase {
    func testSmallMacResourceBudget() {
        let policy = PerformancePolicy.resolve(mode: .automatic, physicalMemory: 8 * 1024 * 1024 * 1024)
        XCTAssertEqual(policy.pinConcurrency, 2)
        XCTAssertEqual(policy.transfers, 4)
        XCTAssertEqual(policy.bufferSize, "16M")
        XCTAssertEqual(policy.driveChunkSize, "16M")
        XCTAssertTrue(policy.lowerMemoryProfile)
        let fast = PerformancePolicy.resolve(mode: .responsive, physicalMemory: 8 * 1024 * 1024 * 1024)
        XCTAssertEqual(fast.bufferSize, "32M")
        XCTAssertEqual(fast.transfers, 8)
    }

    func testBandwidthAndSettingsBounds() {
        var settings = StreamConfig()
        XCTAssertEqual(settings.bandwidthArgument, "off")
        settings.uploadLimitMiB = 3
        XCTAssertEqual(settings.bandwidthArgument, "3M:off")
        settings.downloadLimitMiB = 20
        XCTAssertEqual(settings.bandwidthArgument, "3M:20M")
        settings.pinConcurrency = 5
        XCTAssertNotNil(settings.validationError)
    }

    func testEnvironmentRejectsInheritedCredentialsAndLoaderHooks() {
        let environment = ProcessLaunchEnvironment.make(inherited: [
            "AWS_SECRET_ACCESS_KEY": "fixture", "DYLD_INSERT_LIBRARIES": "/fixture.dylib",
            "RCLONE_RC_PASS": "inherited", "RCLONE_DRIVE_USE_TRASH": "false",
            "HOME": "/forged", "HTTPS_PROXY": "http://proxy.example.invalid:8080"
        ], overrides: ["RCLONE_RC_PASS": "explicit"])
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(environment["RCLONE_DRIVE_USE_TRASH"])
        XCTAssertEqual(environment["RCLONE_RC_PASS"], "explicit")
        XCTAssertNotEqual(environment["HOME"], "/forged")
        XCTAssertEqual(environment["PATH"], ProcessLaunchEnvironment.trustedPath)
    }

    func testObscurationPreservesExactBytes() throws {
        let key = "  é\nline\r\n\u{0}end  "
        let obscured = try RcloneObscuration.obscure(key)
        XCTAssertEqual(try RcloneObscuration.reveal(obscured), key)
        XCTAssertNotEqual(try RcloneObscuration.obscure(key), obscured)
    }

    func testMissingQueueIsNotKnownEmpty() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(RcloneUploadQueue.self, from: Data("{}".utf8)))
        let queue = try JSONDecoder().decode(RcloneUploadQueue.self, from: Data("{\"queue\":[]}".utf8))
        XCTAssertTrue(queue.queue.isEmpty)
    }

    func testPendingQueueBlocksImplicitExit() throws {
        let queue = try JSONDecoder().decode(RcloneUploadQueue.self, from: Data(#"{"queue":[{"id":1,"name":"clip.mov","size":1048576,"expiry":3.5,"tries":1,"delay":5,"uploading":false}]}"#.utf8))
        let vfs = try JSONDecoder().decode(RcloneVFSStats.self, from: Data(#"{"diskCache":{"bytesUsed":1048576,"files":1,"uploadsQueued":1,"uploadsInProgress":0,"erroredFiles":0,"outOfSpace":false}}"#.utf8))
        let safety = UploadSafetySnapshot.assess(queue: queue, vfs: vfs, core: RcloneCoreStats())
        XCTAssertEqual(safety.state, .pending)
        XCTAssertEqual(safety.pendingFiles, 1)
        XCTAssertTrue(safety.requiresExitConsent)
    }

    func testOutOfSpaceAndIncompleteStatsNeedAttention() throws {
        let vfs = try JSONDecoder().decode(RcloneVFSStats.self, from: Data(#"{"diskCache":{"uploadsQueued":0,"uploadsInProgress":0,"erroredFiles":0,"outOfSpace":true}}"#.utf8))
        let safety = UploadSafetySnapshot.assess(queue: RcloneUploadQueue(), vfs: vfs, core: RcloneCoreStats())
        XCTAssertEqual(safety.state, .blocked)
        XCTAssertTrue(safety.requiresExitConsent)
        let missing = try JSONDecoder().decode(RcloneVFSStats.self, from: Data("{}".utf8))
        XCTAssertEqual(UploadSafetySnapshot.assess(queue: RcloneUploadQueue(), vfs: missing, core: RcloneCoreStats()).state, .unknown)
    }

    func testOptionalFatalDiagnosticDoesNotRejectCleanIdle() throws {
        let cache = try JSONDecoder().decode(RcloneVFSStats.self, from: Data(#"{"diskCache":{"uploadsQueued":0,"uploadsInProgress":0,"erroredFiles":0,"outOfSpace":false}}"#.utf8))
        var core = RcloneCoreStats()
        XCTAssertEqual(UploadSafetySnapshot.assess(queue: RcloneUploadQueue(), vfs: cache, core: core).state, .idleObserved)
        core.fatalError = false
        XCTAssertEqual(UploadSafetySnapshot.assess(queue: RcloneUploadQueue(), vfs: cache, core: core).state, .idleObserved)
        core.fatalError = true
        XCTAssertEqual(UploadSafetySnapshot.assess(queue: RcloneUploadQueue(), vfs: cache, core: core).state, .blocked)
    }

    @MainActor
    func testMetadataScannerPreservesHiddenDirtyFiles() async throws {
        let root = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-native-metadata-")
        defer { ServiceFileSafety.removeTemporaryDirectory(root, prefix: "DriveStream-native-metadata-") }
        let directory = root.appendingPathComponent("vfsMeta", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31, 0, 0, 0, 0]).write(to: directory.appendingPathComponent(".DS_Store"))
        try Data(#"{"Dirty":true}"#.utf8).write(to: directory.appendingPathComponent(".env"))
        let observation = await DirtyCacheInspection.inspect(metadataPath: directory.path, cacheRoot: root)
        XCTAssertTrue(observation.complete)
        XCTAssertEqual(observation.dirtyFiles, 1)
    }

    func testDiagnosticTokensRemainRedacted() {
        let result = DiagnosticRedactor.redact(#"{"password":"prefix\"secret-tail","access_token":"fixture-token"}"#)
        XCTAssertFalse(result.contains("secret-tail"))
        XCTAssertFalse(result.contains("fixture-token"))
    }
}
