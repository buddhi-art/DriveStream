import Darwin
import Foundation

/// Private offline fixtures: no real OAuth, mount, account, Keychain or downloads.
@main
@MainActor
struct ReviewRegressionTests {
    private static var checks = 0
    private struct Failure: Error { let message: String }
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        checks += 1
        print("PASS: " + message)
    }
    private static func rejects(_ message: String, _ operation: () async throws -> Void) async throws -> any Error {
        do { try await operation() }
        catch { checks += 1; print("PASS: " + message); return error }
        throw Failure(message: message + " unexpectedly succeeded")
    }
    static func main() async throws {
        let root = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-review-tests-")
        defer { ServiceFileSafety.removeTemporaryDirectory(root, prefix: "DriveStream-review-tests-") }
        try await installerChecks(root: root)
        try modelChecks()
        try await rootChecks(root: root)
        print("ALL REVIEW REGRESSIONS PASSED (\(checks) checks)")
    }
    private static func installerChecks(root: URL) async throws {
        for version in ["v1.75.2", "v2.0.0"] {
            for architecture in ["arm64", "amd64"] {
                let release = try RcloneDownloads.Release(versionText: "rclone " + version + "\n", architecture: architecture)
                let filename = "rclone-\(version)-osx-\(architecture).zip"
                try expect(release.archiveName == filename, "archive name uses exact release")
                try expect(release.downloadURL.absoluteString == "https://downloads.rclone.org/\(version)/\(filename)", "download is versioned, never current")
                try expect(release.checksumURL.absoluteString == "https://downloads.rclone.org/\(version)/SHA256SUMS", "checksum directory matches download")
                let digest = String(repeating: "a", count: 64)
                try expect(DependencyArchiveSafety.checksum(in: digest + "  " + filename, for: release.archiveName) == digest, "checksum selects fetched filename")
            }
        }
        for value in ["rclone v1.2", "rclone v1.2.3/../../other", "rclone current", "rclone v1.2.3\ninjected"] {
            _ = try await rejects("malformed release rejected") { _ = try RcloneDownloads.Release(versionText: value, architecture: "arm64") }
        }
        _ = try await rejects("unsupported architecture rejected") { _ = try RcloneDownloads.Release(versionText: "rclone v1.2.3", architecture: "x86_64") }
        let archive = root.appendingPathComponent("archive-fixture")
        try ServiceFileSafety.createPrivateFile(archive, data: Data("abc".utf8))
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try await DependencyManager.verifyArchiveChecksum(at: archive, expectedHash: digest)
        let error = try await rejects("wrong checksum fails closed") { try await DependencyManager.verifyArchiveChecksum(at: archive, expectedHash: String(repeating: "0", count: 64)) }
        try expect(error is DependencyError, "hash mismatch is an installer verification error")
        try ServiceFileSafety.atomicWrite(Data("changed bytes".utf8), to: archive)
        _ = try await rejects("changed bytes cannot pass old digest") { try await DependencyManager.verifyArchiveChecksum(at: archive, expectedHash: digest) }
    }
    private static func modelChecks() throws {
        try expect(RcloneAbout(used: Int64.max, free: 1).effectiveTotal == nil, "quota overflow cannot trap")
        try expect(RcloneAbout(used: Int64.max - 1, free: 1).effectiveTotal == Int64.max, "exact quota boundary allowed")
        try expect(RcloneAbout(total: 100, used: Int64.max, free: 1).effectiveTotal == 100, "explicit quota takes precedence")
        try expect(RcloneAbout(used: 0, free: 100).effectiveTotal == 100, "empty drive has positive capacity")
        let privateText = #"/Users/PRIVATE_USER/Cloud/PRIVATE_FILE.mov http://127.0.0.1:43210/?state=PRIVATE_STATE {"access_token":"PRIVATE_TOKEN"} malformed SECRET_WITHOUT_KEY"#
        for reason in ["invalid_grant", "network is unreachable", "429 rate limit", "macFUSE", "unknown flag", "encrypted remote is not configured", "not empty", "unknown failure"] {
            let issue = DriveStreamIssue.mountFailure(description: reason + privateText, log: privateText)
            let presentation = issue.title + issue.summary + issue.details
            try expect(!presentation.contains("PRIVATE_") && !presentation.contains("SECRET_WITHOUT_KEY") && !presentation.contains("127.0.0.1"), "failure classification discards all private helper text")
            try expect(issue.details.contains("Open Logs"), "failure points to private logs")
        }
        let list = try GoogleSharedDrive.decodeList(#"[{"id":"Drive_1","name":"  Team\n東京  "},{"id":"Drive_1","name":"duplicate"},{"id":"Drive-2","name":"Finance"}]"#)
        try expect(list == [GoogleSharedDrive(id: "Drive_1", name: "Team 東京"), GoogleSharedDrive(id: "Drive-2", name: "Finance")], "IDs deduplicate and Unicode labels remain single-line")
        try expect(try GoogleSharedDrive.decodeList("[]").isEmpty, "empty shared drive list is valid")
        for value in ["", "../escape", "drive\ninjected", "drive:other", "https://drive.google.com/id", "é", String(repeating: "x", count: 257)] {
            try expect(!GoogleSharedDrive.validID(value), "unsafe or oversized drive ID rejected")
        }
        for output in ["{}", "null", "garbage PRIVATE_TOKEN", "[{\"id\":\"../escape\",\"name\":\"x\"}]", "[{\"id\":\"okay\"}]"] {
            do { _ = try GoogleSharedDrive.decodeList(output); throw Failure(message: "Malformed list accepted") }
            catch is DriveRootError { checks += 1 }
        }
        var configuration = try JSONDecoder().decode(StreamConfig.self, from: Data("{}".utf8))
        try expect(configuration.sharedDriveID.isEmpty, "older settings default to My Drive")
        let previous = configuration
        configuration.sharedDriveID = "Drive_1"
        try expect(configuration.mountProfileDiffers(from: previous), "root changes require remount")
        try expect(try JSONDecoder().decode(StreamConfig.self, from: JSONEncoder().encode(configuration)).sharedDriveID == "Drive_1", "root survives settings persistence")
    }
    private static func rootChecks(root: URL) async throws {
        guard let python = ProcessInfo.processInfo.environment["DRIVESTREAM_TEST_PYTHON"],
              python.hasPrefix("/"), !python.contains("\n"), !python.contains(" ") else { throw Failure(message: "Absolute fixture Python required") }
        let paths = DriveStreamPaths(applicationSupportDirectory: root.appendingPathComponent("support"), homeDirectory: root.appendingPathComponent("home"))
        try paths.prepareFileSystem()
        try ServiceFileSafety.createPrivateFile(paths.rcloneBinary, data: Data(("#!" + python + "\n" + helper).utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.rcloneBinary.path)
        let credentials = ReviewMemoryCredentials()
        let service = RcloneConfigService(paths: paths, credentialStore: credentials)
        let original = Data("# keep comment\n[gdrive]\ntype = drive\ntoken = ORIGINAL_PRIVATE_TOKEN\nclient_id = fixture-client\nclient_secret = PRIVATE_CLIENT_SECRET\nteam_drive = OldDrive\nroot_folder_id = old-subfolder\nshared_with_me = true\nunknown_option = keep this\n\n[gdrive-crypt]\ntype = crypt\nremote = gdrive:Encrypted\npassword = PRIVATE_CRYPT_KEY\n\n[other]\ntype = local\n".utf8)
        try ServiceFileSafety.atomicWrite(original, to: paths.configFile)
        func mode(_ text: String) throws { try ServiceFileSafety.atomicWrite(Data(text.utf8), to: paths.applicationSupportDirectory.appendingPathComponent("mode")) }
        try mode("success")
        let listed = try await service.sharedDrives(remoteName: "gdrive")
        try expect(listed.count == 2 && listed[0].id == "Shared_A", "real service lists drives through a private candidate")
        try expect(try Data(contentsOf: paths.configFile) == original, "discovery and candidate refresh never rewrite live config")
        try expect(service.profile(for: "gdrive")?.sharedDriveID == "OldDrive", "hand-edited team_drive is preserved")
        try mode("list-empty")
        try expect(try await service.sharedDrives(remoteName: "gdrive").isEmpty, "service accepts empty list")
        for failureMode in ["fail", "list-bad"] {
            try mode(failureMode)
            let failure = try await rejects("list failure preserves root") { _ = try await service.sharedDrives(remoteName: "gdrive") }
            try expect(!failure.localizedDescription.contains("PRIVATE_"), "list errors never echo output")
            try expect(try Data(contentsOf: paths.configFile) == original, "failed discovery preserves config bytes")
        }
        try mode("success")
        _ = try await rejects("injected root rejected") { _ = try await service.setDriveRoot(remoteName: "gdrive", sharedDriveID: "A\n[other]", expectedSharedDriveID: "OldDrive") }
        for failureMode in ["fail", "tamper"] {
            try mode(failureMode)
            _ = try await rejects("failed or tampered verification cannot publish") { _ = try await service.setDriveRoot(remoteName: "gdrive", sharedDriveID: "Shared_A", expectedSharedDriveID: "OldDrive") }
            try expect(try Data(contentsOf: paths.configFile) == original, "failed root change preserves config bytes")
        }
        try mode("concurrent")
        _ = try await rejects("concurrent live edit wins") { _ = try await service.setDriveRoot(remoteName: "gdrive", sharedDriveID: "Shared_A", expectedSharedDriveID: "OldDrive") }
        try expect(try Data(contentsOf: paths.configFile) == original + Data("# external edit\n".utf8), "concurrent edit not overwritten or rolled back")
        try ServiceFileSafety.atomicWrite(original, to: paths.configFile)
        try mode("delay")
        let operation = Task { try await service.setDriveRoot(remoteName: "gdrive", sharedDriveID: "Shared_A", expectedSharedDriveID: "OldDrive") }
        let started = paths.applicationSupportDirectory.appendingPathComponent("started")
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: started.path) {
                guard ContinuousClock.now < deadline else { throw Failure(message: "Fixture never started") }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch { operation.cancel(); _ = try? await operation.value; throw error }
        operation.cancel()
        do { _ = try await operation.value; throw Failure(message: "Cancelled root change succeeded") }
        catch is CancellationError { checks += 1 }
        let pid = Int32(try String(contentsOf: started, encoding: .utf8))!
        try expect(kill(pid, 0) == -1 && errno == ESRCH, "cancelled helper joined before return")
        try expect(try Data(contentsOf: paths.configFile) == original, "cancellation keeps original root and credentials")
        try mode("success")
        let shared = try await service.setDriveRoot(remoteName: "gdrive", sharedDriveID: "Shared_A", expectedSharedDriveID: "OldDrive")
        let published = try String(contentsOf: paths.configFile, encoding: .utf8)
        try expect(shared.sharedDriveID == "Shared_A" && shared.cacheNamespace != nil, "root and cache namespace publish atomically")
        try expect(published.contains("REFRESHED_PRIVATE_TOKEN") && published.contains("unknown_option = keep this") && published.contains("PRIVATE_CRYPT_KEY") && published.contains("# keep comment"), "refresh, secrets, crypt and unrelated config preserved")
        try expect(!published.contains("root_folder_id") && !published.contains("shared_with_me"), "explicit root clears conflicting selectors")
        try expect((try FileManager.default.attributesOfItem(atPath: paths.configFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "published config stays 0600")
        let firstCache = try RcloneDriveRootService.prepareCacheDirectory(namespace: shared.cacheNamespace, root: paths.cacheDirectory)
        try expect(firstCache != paths.cacheDirectory, "new root cannot reuse legacy cache")
        let personal = try await service.setDriveRoot(remoteName: "gdrive", sharedDriveID: "", expectedSharedDriveID: "Shared_A")
        let secondCache = try RcloneDriveRootService.prepareCacheDirectory(namespace: personal.cacheNamespace, root: paths.cacheDirectory)
        try expect(personal.sharedDriveID == nil && secondCache != firstCache && secondCache != paths.cacheDirectory, "return to My Drive also has isolated cache")
        try expect(credentials.calls == 0, "root APIs never touch Keychain credentials")
        _ = try await rejects("stale root cannot overwrite current config") { _ = try await service.setDriveRoot(remoteName: "gdrive", sharedDriveID: "Shared_B", expectedSharedDriveID: "OldDrive") }
        let beforeReconnect = try await service.setDriveRoot(remoteName: "gdrive", sharedDriveID: "Shared_B", expectedSharedDriveID: "")
        let reconnected = try await service.connectGoogleDrive(remoteName: "gdrive", clientID: "", clientSecret: "")
        try expect(reconnected.about == nil && reconnected.profile.sharedDriveID == "Shared_B" && reconnected.profile.cacheNamespace == beforeReconnect.cacheNamespace, "Shared Drive reconnect needs no quota and preserves root")
        let clean = await DirtyCacheInspection.inspectUnmountedCache(cacheRoot: secondCache)
        try expect(clean.complete && clean.dirtyFiles == 0, "unused cache is safe to leave")
        let vfs = secondCache.appendingPathComponent("vfs", isDirectory: true)
        try FileManager.default.createDirectory(at: vfs, withIntermediateDirectories: false)
        let missing = await DirtyCacheInspection.inspectUnmountedCache(cacheRoot: secondCache)
        try expect(!missing.complete, "data without metadata cannot authorize root change")
        let metadata = secondCache.appendingPathComponent("vfsMeta", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        try ServiceFileSafety.createPrivateFile(metadata.appendingPathComponent("dirty"), data: Data(#"{"Dirty":true}"#.utf8))
        let dirty = await DirtyCacheInspection.inspectUnmountedCache(cacheRoot: secondCache)
        try expect(dirty.complete && dirty.dirtyFiles == 1, "dormant dirty writes are detected")
        for namespace in ["../outside", "bad", "../" + UUID().uuidString] {
            _ = try await rejects("invalid namespace cannot escape cache") { _ = try RcloneDriveRootService.cacheDirectory(namespace: namespace, root: paths.cacheDirectory) }
        }
    }
    private static let helper = #"""
import json, os, stat, sys, time
from pathlib import Path
root = Path(__file__).resolve().parent.parent
args = sys.argv[1:]
assert args[0] == "--config"
config = Path(args[1])
assert config != root / "rclone.conf"
assert config.name == "rclone.conf" and config.parent.name.startswith(("DriveStream-drive-list-", "DriveStream-drive-root-", "DriveStream-google-config-", "DriveStream-oauth-"))
assert stat.S_IMODE(config.stat().st_mode) == 0o600
assert stat.S_IMODE(config.parent.stat().st_mode) == 0o700
assert not any("PRIVATE_" in arg for arg in args)
assert not any("PRIVATE_" in value for value in os.environ.values())
command = args[2:]
text = config.read_text()
mode = (root / "mode").read_text()
if command[0] == "authorize":
    assert command == ["authorize", "drive"]
    print(json.dumps({"access_token":"FAKE_ACCESS", "refresh_token":"FAKE_REFRESH"}))
    sys.exit(0)
if command[0] == "config":
    assert command == ["config", "userinfo", "gdrive:", "--json"]
    print(json.dumps({"email":"fixture@example.invalid"}))
    sys.exit(0)
if mode == "fail":
    print("PRIVATE_TOKEN /Users/PRIVATE_USER/PRIVATE_FILE.mov http://127.0.0.1:45678/", file=sys.stderr)
    sys.exit(22)
if mode == "delay":
    (root / "started").write_text(str(os.getpid()))
    while True:
        time.sleep(0.05)
if command[0] == "backend":
    assert command == ["backend", "drives", "gdrive:"]
    assert "team_drive" not in text and "root_folder_id" not in text and "shared_with_me" not in text
    config.write_text(text.replace("ORIGINAL_PRIVATE_TOKEN", "REFRESHED_PRIVATE_TOKEN"))
    if mode == "list-bad":
        print("malformed PRIVATE_TOKEN")
    elif mode == "list-empty":
        print("[]")
    else:
        print(json.dumps([{"id":"Shared_A", "name":"Design"}, {"id":"Shared_B", "name":"Finance"}]))
else:
    assert command == ["lsf", "gdrive:", "--dirs-only", "--max-depth", "1"]
    assert "root_folder_id" not in text and "shared_with_me" not in text
    if mode == "concurrent":
        with (root / "rclone.conf").open("a") as file:
            file.write("# external edit\n")
    if mode == "tamper":
        text = text.replace("team_drive = Shared_A", "team_drive = OtherDrive")
    config.write_text(text.replace("ORIGINAL_PRIVATE_TOKEN", "REFRESHED_PRIVATE_TOKEN"))
"""#
}

@MainActor
private final class ReviewMemoryCredentials: RcloneCredentialStore {
    var calls = 0
    private var values: [String: String] = [:]
    func save(_ secret: String, for account: String) throws { calls += 1; values[account] = secret }
    func readString(for account: String) throws -> String? { calls += 1; return values[account] }
    func delete(for account: String) throws { calls += 1; values.removeValue(forKey: account) }
}
