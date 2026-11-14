// Model-level smoke tests for DriveStream.
//
// These intentionally avoid SwiftUI views so they can be compiled with the
// Command Line Tools on a machine that does not have a full Xcode install.
// Run them with Scripts/run-model-tests.sh or `make smoke`.

import Foundation

@main
@MainActor
struct DriveStreamSmokeTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            reportFailure("FAIL: \(message)\n")
            exit(1)
        }
        print("ok - \(message)")
    }

    static func reportFailure(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    }

    static func main() async throws {
        try await testReliabilityAndRecovery()
        expect(SizeParser.bytes(from: "10G") == 10 * 1024 * 1024 * 1024, "SizeParser parses 10G")
        expect(SizeParser.bytes(from: "512MiB") == 512 * 1024 * 1024, "SizeParser parses 512MiB")
        expect(SizeParser.bytes(from: "nonsense") == nil, "SizeParser rejects nonsense")
        expect(SizeParser.canonicalString(from: "1024M") == "1G", "SizeParser canonicalizes 1024M to 1G")
        expect(SizeParser.canonicalString(from: "1023B") == "1023B", "Non-unit-aligned cache sizes retain an explicit byte suffix")
        expect(SizeParser.bytes(from: "9223372036854775808B") == nil, "SizeParser rejects Int64 overflow without trapping")
        expect(DurationParser.seconds(from: "1h") == 3600, "DurationParser parses 1h")
        expect(DurationParser.seconds(from: "30m") == 1800, "DurationParser parses 30m")
        expect(DurationParser.seconds(from: "forever") == nil, "DurationParser rejects invalid input")
        expect(StreamConfig.rcloneByteSizeArgument(5_000_000_000_000) == "5000000000000B", "rclone byte-size arguments always use an explicit B suffix")
        expect(RcloneFlagCompatibility.supportedAppleMetadataFlags(in: "").isEmpty, "Apple metadata flags are omitted when help is unavailable")
        let supportedHelp = """
              --noappledouble   Ignore Apple Double files
              --noapplexattr    Ignore Apple extended attributes
        """
        expect(RcloneFlagCompatibility.supportedAppleMetadataFlags(in: supportedHelp) == ["--noappledouble", "--noapplexattr"], "Canonical Apple metadata flags are accepted when advertised")
        let partialHelp = """
              --noappledouble   Ignore Apple Double files
        """
        expect(RcloneFlagCompatibility.supportedAppleMetadataFlags(in: partialHelp) == ["--noappledouble"], "Each advertised Apple metadata flag is gated independently")
        let hyphenatedHelp = """
              --no-appledouble   Invalid spelling
              --no-applexattr    Invalid spelling
        """
        expect(RcloneFlagCompatibility.supportedAppleMetadataFlags(in: hyphenatedHelp).isEmpty, "Invalid hyphenated flag names are never selected")

        var config = StreamConfig()
        expect(config.validationError == nil, "Default StreamConfig is valid")
        expect(config.normalizedCacheMaxSize == "10G", "Default cache size is 10G")
        expect(config.normalizedCacheMaxAge == "1h", "Default cache age is 1h")
        expect(config.effectiveRemoteSpecifier == "gdrive:", "Drive remote specifier")
        config.useEncryption = true
        expect(config.effectiveRemoteSpecifier == "gdrive-crypt:", "Crypt remote specifier")
        config.useEncryption = false
        config.volumeName = "Acme/Team: Drive"
        expect(config.sanitizedVolumeName == "Acme-Team- Drive", "Volume name sanitization")
        expect(config.resolvedMountPath(volumesWritable: false).contains("DriveStreamVolumes"), "Home mount path")
        config.mountLocation = .volumes
        expect(config.resolvedMountPath(volumesWritable: true).hasPrefix("/Volumes/"), "Volumes mount path when writable")
        expect(config.resolvedMountPath(volumesWritable: false).contains("DriveStreamVolumes"), "Volumes preference falls back to home")
        config.customMountPath = "/tmp/DriveStream-Test-Mount"
        expect(config.resolvedMountPath(volumesWritable: false) == "/tmp/DriveStream-Test-Mount", "Custom mount path")
        config.customMountPath = "/"
        expect(config.validationError != nil, "Root mount path is rejected")
        config.customMountPath = ""
        config.cacheMaxSize = "10MB"
        expect(config.validationError != nil, "Too-small cache is rejected")
        config.cacheMaxSize = "10G"

        let aboutJSON = #"{"total":5000000000000,"used":1200000000000,"free":3800000000000,"trashed":1000,"objects":42}"#.data(using: .utf8)!
        let about = try JSONDecoder().decode(RcloneAbout.self, from: aboutJSON)
        expect(about.effectiveTotal == 5_000_000_000_000, "About total decodes")
        expect(about.used == 1_200_000_000_000, "About used decodes")
        expect(about.usedFraction != nil, "About fraction exists")

        let coreJSON = #"""
        {
          "speed": 5242880.0,
          "bytes": 104857600,
          "totalBytes": 209715200,
          "transfers": 1,
          "elapsedTime": 12.5,
          "errors": 0,
          "fatalError": false,
          "transferring": [
            {"name":"Movies/Clip.mov","size":209715200,"bytes":104857600,"percentage":50,"speed":5242880.0,"srcFs":"/Users/me/Library/Application Support/DriveStream/cache/vfs/gdrive/Movies/Clip.mov","dstFs":"gdrive:Movies/Clip.mov","startedAt":"2026-10-25T09:00:00Z"}
          ]
        }
        """#.data(using: .utf8)!
        let core = try JSONDecoder().decode(RcloneCoreStats.self, from: coreJSON)
        expect(core.transferring.count == 1, "Core stats decodes transfers")
        let item = TransferItem(transfer: core.transferring[0], remoteNames: ["gdrive", "gdrive-crypt"])
        expect(item.direction == .upload, "Local -> remote transfer is classified as upload")
        expect(item.name == "Clip.mov", "Transfer display name")
        expect(abs(item.progress - 0.5) < 0.0001, "Transfer progress")

        let vfsJSON = #"""
        {
          "fs": "gdrive:",
          "inUse": 2,
          "diskCache": {
            "bytesUsed": 1932735283,
            "files": 12,
            "uploadsInProgress": 1,
            "uploadsQueued": 2,
            "path": "/tmp/cache"
          },
          "metadataCache": {"dirs": 100, "files": 500}
        }
        """#.data(using: .utf8)!
        let vfs = try JSONDecoder().decode(RcloneVFSStats.self, from: vfsJSON)
        expect(vfs.cacheBytesUsed == 1_932_735_283, "VFS cache bytes decode")
        expect(vfs.queuedUploads == 3, "VFS queued uploads decode")
        expect(vfs.activeStreams == 2, "VFS active streams decode")

        let authorizeOutput = """
        Waiting for code...
        Got code
        Paste the following into your remote machine --->
        {\n  "access_token": "ya29.test",\n  "token_type": "Bearer",\n  "refresh_token": "refresh",\n  "expiry": "2026-10-25T10:00:00Z"\n}
        <---End paste
        """
        let token = RcloneConfigService.extractTokenJSON(from: authorizeOutput)
        expect(token != nil, "OAuth token JSON extraction succeeds")
        expect(token?.contains("\"access_token\"") == true, "Extracted token contains access_token")
        expect(RcloneConfigService.extractTokenJSON(from: "no token here") == nil, "Missing token is rejected")

        let noisyJSON = "some warning\n" + #"{"total": 1024, "used": 512}"#
        guard let extracted = RcloneConfigService.extractJSONObject(from: noisyJSON) else {
            reportFailure("FAIL: JSON object extraction\n")
            exit(1)
        }
        let extractedAbout = try JSONDecoder().decode(RcloneAbout.self, from: extracted)
        expect(extractedAbout.total == 1024, "JSON object extraction ignores noise")

        let jobJSON = #"{"id":7,"finished":true,"success":true,"error":"","duration":1.2}"#.data(using: .utf8)!
        let job = try JSONDecoder().decode(RcloneJobStatus.self, from: jobJSON)
        expect(job.finished && job.succeeded, "Job status decodes success")

        // Direct config writing must preserve unrelated remotes/options and avoid
        // ever invoking rclone's interactive OAuth config state machine.
        let configRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DriveStreamConfigWriter-\(UUID().uuidString)", isDirectory: true)
        let configPaths = DriveStreamPaths(
            applicationSupportDirectory: configRoot.appendingPathComponent("support", isDirectory: true),
            homeDirectory: configRoot.appendingPathComponent("home", isDirectory: true)
        )
        do {
            try configPaths.prepareFileSystem()
            let initialConfig = """
            [gdrive]
            type = drive
            token = old-token
            client_id = old-id
            client_secret = old-secret
            team_drive = untouched

            [gdrive-crypt]
            type = crypt
            remote = gdrive:
            password = obscured-password
            """
            try initialConfig.write(to: configPaths.configFile, atomically: true, encoding: .utf8)
            let configService = RcloneConfigService(
                paths: configPaths,
                keychain: KeychainHelper(service: "com.drivestream.tests.\(UUID().uuidString)")
            )
            let tokenValue = #"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expiry":"2027-01-01T00:00:00Z"}"#
            try configService.writeDriveRemote(
                remoteName: "gdrive",
                token: tokenValue,
                clientID: "",
                clientSecret: ""
            )
            var written = try String(contentsOf: configPaths.configFile, encoding: .utf8)
            expect(written.contains("[gdrive-crypt]"), "Drive config writer preserves the crypt remote")
            expect(written.contains("team_drive = untouched"), "Drive config writer preserves unrelated options")
            expect(written.contains("token = \(tokenValue)"), "Drive config writer stores the token")
            expect(!written.contains("client_id"), "Default OAuth client clears stale custom credentials")
            expect(!written.contains("old-token"), "Drive config writer replaces the previous token")

            try configService.writeDriveRemote(
                remoteName: "gdrive",
                token: tokenValue,
                clientID: "new.apps.googleusercontent.com",
                clientSecret: "new-secret"
            )
            written = try String(contentsOf: configPaths.configFile, encoding: .utf8)
            expect(written.contains("client_id = new.apps.googleusercontent.com"), "Custom OAuth client ID is written")
            expect(written.contains("client_secret = new-secret"), "Custom OAuth client secret is written")
            let attributes = try FileManager.default.attributesOfItem(atPath: configPaths.configFile.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            expect(permissions & 0o777 == 0o600, "rclone config is mode 0600")
        } catch {
            reportFailure("FAIL: config writer test failed: \(error)\n")
            try? FileManager.default.removeItem(at: configRoot)
            exit(1)
        }
        try? FileManager.default.removeItem(at: configRoot)

        // CommandRunner must not use Process.waitUntilExit: on recent macOS builds
        // that path can hang for commands with large outputs. Test ordinary output,
        // a >256 KB output capture, and a real timeout.
        do {
            let echo = try await CommandRunner.run(executable: "/bin/echo", arguments: ["hello"], timeout: 10)
            expect(echo.standardOutput.contains("hello"), "CommandRunner captures ordinary output")
        } catch {
            reportFailure("FAIL: CommandRunner echo failed: \(error)\n")
            exit(1)
        }

        let largeFile = FileManager.default.temporaryDirectory.appendingPathComponent("DriveStreamLargeCommandOutput-\(UUID().uuidString).txt")
        let largePayload = String(repeating: "DriveStream output line.\n", count: 12_000)
        do {
            try largePayload.write(to: largeFile, atomically: true, encoding: .utf8)
            let cat = try await CommandRunner.run(executable: "/bin/cat", arguments: [largeFile.path], timeout: 10)
            expect(cat.standardOutput.count > 250_000, "CommandRunner drains large output without hanging")
        } catch {
            reportFailure("FAIL: CommandRunner large-output test failed: \(error)\n")
            try? FileManager.default.removeItem(at: largeFile)
            exit(1)
        }
        try? FileManager.default.removeItem(at: largeFile)

        do {
            _ = try await CommandRunner.run(executable: "/bin/sleep", arguments: ["2"], timeout: 1)
            reportFailure("FAIL: CommandRunner did not time out\n")
            exit(1)
        } catch let error as CommandRunnerError {
            if case .timedOut = error {
                expect(true, "CommandRunner kills and reports timed-out commands")
            } else {
                reportFailure("FAIL: CommandRunner returned the wrong error: \(error)\n")
                exit(1)
            }
        } catch {
            reportFailure("FAIL: Unexpected CommandRunner error: \(error)\n")
            exit(1)
        }

        print("All DriveStream model smoke tests passed.")
    }
    static func testReliabilityAndRecovery() async throws {
        let notice = "2026/11/05 23:00:00 NOTICE: Serving remote control on http://127.0.0.1:43210/"
        expect(RCServerEndpoint.parseAnnouncement(notice)?.port == 43210, "RC endpoint uses the kernel-assigned port from a NOTICE header")
        expect(RCServerEndpoint.parseAnnouncement("2026/11/05 23:00:00 INFO : file NOTICE: Serving remote control on http://127.0.0.1:43210/") == nil, "A filename containing a fake announcement cannot select the RC endpoint")
        expect(RCServerEndpoint.parseAnnouncement("2026/11/05 23:00:00 NOTICE: Serving remote control on http://example.com:43210/") == nil, "RC discovery rejects non-loopback endpoints")
        expect(RCServerEndpoint.parseAnnouncement("2026/11/05 23:00:00 NOTICE: Serving remote control on http://user:secret@127.0.0.1:43210/") == nil, "RC discovery rejects credential-bearing URLs")
        expect(RCServerEndpoint.parseAnnouncement("2026/11/05 23:00:00 NOTICE: Serving remote control on http://127.0.0.1:0/") == nil, "An unassigned port is not a discovered endpoint")
        expect(!RCServerEndpoint.isAllowed(URL(string: "http://127.0.0.1:43210/redirect")!), "RC discovery rejects URL paths")

        let privateJSON = #"{"password":"first\"SENSITIVE_SUFFIX","access_token":"SECRET_TOKEN","refresh_token":"SECRET_REFRESH"}"#
        let redacted = DiagnosticRedactor.redact(privateJSON)
        expect(!redacted.contains("SENSITIVE_SUFFIX") && !redacted.contains("SECRET_TOKEN") && !redacted.contains("SECRET_REFRESH"), "Diagnostics redact complete JSON secrets including escaped quotes")
        expect((try? JSONSerialization.jsonObject(with: Data(redacted.utf8))) != nil, "Redacted JSON remains readable")
        let cli = DiagnosticRedactor.redact("--rc-pass=EQUALS_SECRET --client-secret \"QUOTED SECRET\" Authorization: Basic BASIC_SECRET")
        expect(!cli.contains("EQUALS_SECRET") && !cli.contains("QUOTED SECRET") && !cli.contains("BASIC_SECRET"), "Diagnostics redact equals flags, quoted values and Basic headers")
        expect(DiagnosticRedactor.redact("token = RAW_SECRET").contains("RAW_SECRET") == false, "INI token values are fully redacted")
        expect(DiagnosticRedactor.redact(String(repeating: "x", count: 20_000)).count <= 12_000, "Diagnostic details are bounded")
        let network = DriveStreamIssue.mountFailure(description: "macFUSE: network is unreachable")
        expect(network.title == "The drive could not connect" && network.recovery == .retryMount, "Concrete network errors outrank a backend label")
        let rate = DriveStreamIssue.mountFailure(description: "macFUSE: HTTP 429 rate limit")
        expect(rate.title == "Google Drive is limiting requests", "Google rate limits receive a targeted summary")
        let crypt = DriveStreamIssue.mountFailure(description: "Encryption is enabled but the encrypted remote is not configured")
        expect(crypt.recovery == .openSetup, "Crypt configuration failures direct users to Setup")

        let defaultCredentials = try GoogleOAuthCredentials.resolve(useCustomClient: false, clientID: "stale-id", enteredSecret: "stale-secret", storedClientID: "stale-id", storedSecret: "stored-secret")
        expect(defaultCredentials.clientID.isEmpty && defaultCredentials.clientSecret.isEmpty, "Default credentials never inherit stale personal OAuth data")
        let stored = try GoogleOAuthCredentials.resolve(useCustomClient: true, clientID: "same-id", enteredSecret: "", storedClientID: "same-id", storedSecret: "stored-secret")
        expect(stored.clientSecret == "stored-secret", "Blank personal secret reuses only the matching Keychain copy")
        let explicit = try GoogleOAuthCredentials.resolve(useCustomClient: true, clientID: "same-id", enteredSecret: "new-secret", storedClientID: "same-id", storedSecret: "stored-secret")
        expect(explicit.clientSecret == "new-secret", "A newly entered OAuth secret takes precedence")
        do {
            _ = try GoogleOAuthCredentials.resolve(useCustomClient: true, clientID: "different-id", enteredSecret: "", storedClientID: "same-id", storedSecret: "stored-secret")
            expect(false, "A changed Client ID must not reuse another client's secret")
        } catch is RcloneConfigError {
            expect(true, "A changed Client ID cannot reuse another client's Keychain secret")
        }

        var health = TelemetryRecoveryState()
        expect(health.nextPollInterval == 2 && !health.shouldWarn, "Healthy telemetry polls every two seconds")
        health.recordFailure(isTransient: true)
        expect(health.nextPollInterval == 4 && !health.shouldWarn, "First transient telemetry failure backs off without alarming the user")
        health.recordFailure(isTransient: true)
        health.recordFailure(isTransient: true)
        expect(health.shouldWarn && health.nextPollInterval == 16, "Three failed polls surface a warning with bounded backoff")
        for _ in 0..<20 { health.recordFailure(isTransient: true) }
        expect(health.nextPollInterval == 30, "Telemetry backoff never exceeds thirty seconds")
        health.recordSuccess()
        expect(health.consecutiveFailures == 0 && !health.shouldWarn && health.nextPollInterval == 2, "Successful telemetry clears its warning and restores normal polling")
        health.recordFailure(isTransient: false)
        expect(health.shouldWarn, "Permanent telemetry failures surface without blind retries")

        let transient = RetryProbe(failures: 2, error: .http(status: 503, message: "temporary"))
        let value = try await RCRetryPolicy().perform(sleep: { await transient.sleep($0) }) { try await transient.next() }
        let transientState = await transient.snapshot()
        expect(value == 42 && transientState.attempts == 3 && transientState.delays == [0.5, 1], "Read-only RC retry uses a three-attempt exponential schedule")
        let exhausted = RetryProbe(failures: 10, error: .http(status: 429, message: "busy"))
        do {
            _ = try await RCRetryPolicy().perform(sleep: { await exhausted.sleep($0) }) { try await exhausted.next() }
            expect(false, "Repeated transient failures must stop at the retry cap")
        } catch let error as RcloneRCError {
            expect(error.statusCode == 429, "Retry exhaustion preserves the original HTTP error")
        }
        let exhaustedState = await exhausted.snapshot()
        expect(exhaustedState.attempts == 3, "Transient retries never exceed the attempt cap")
        let permanent = RetryProbe(failures: 10, error: .http(status: 401, message: "denied"))
        do {
            _ = try await RCRetryPolicy().perform(sleep: { await permanent.sleep($0) }) { try await permanent.next() }
            expect(false, "Authentication must not be retried")
        } catch let error as RcloneRCError {
            expect(error.isAuthenticationFailure, "Authentication failure remains classified")
        }
        let permanentState = await permanent.snapshot()
        expect(permanentState.attempts == 1 && permanentState.delays.isEmpty, "Authentication errors are never automatically retried")
        let cancelledProbe = RetryProbe(failures: 0, error: .http(status: 503, message: "unused"))
        let cancelled = Task {
            try await RCRetryPolicy().perform(sleep: { await cancelledProbe.sleep($0) }) { try await cancelledProbe.next() }
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; expect(false, "Cancelled requests must not begin") }
        catch is CancellationError { expect(true, "Retry policy preserves cancellation") }
        let cancelledState = await cancelledProbe.snapshot()
        expect(cancelledState.attempts == 0, "Pre-cancelled telemetry never calls the transport")

        let mountFixture = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-mount-parser-")
        defer { ServiceFileSafety.removeTemporaryDirectory(mountFixture, prefix: "DriveStream-mount-parser-") }
        let directory = mountFixture.appendingPathComponent("DriveStream Sample", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let alias = mountFixture.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let escapedPath = directory.resolvingSymlinksInPath().path.replacingOccurrences(of: " ", with: "\\040")
        expect(MountTable.containsMount(path: alias.path, table: "localhost:/ on \(escapedPath) (nfs, nodev)"), "Mount inspection canonicalizes existing aliases and escaped spaces")
        expect(!MountTable.containsMount(path: "/tmp/DriveStream", table: "localhost:/ on /private/tmp/DriveStream-other (nfs)"), "Mount inspection requires an exact path")
        expect(MountPresence.unknown.mayBeMounted && !MountPresence.unmounted.mayBeMounted, "Unknown mount inspection is never interpreted as a successful detach")

        let profilePaths = DriveStreamPaths(applicationSupportDirectory: mountFixture.appendingPathComponent("support"), homeDirectory: mountFixture.appendingPathComponent("home"))
        let profileHelp = "      --noappledouble    Ignore AppleDouble\n      --noapplexattr     Ignore Apple xattrs"
        var fastConfiguration = StreamConfig()
        fastConfiguration.performanceMode = .responsive
        let profile = MountArgumentsBuilder.build(
            config: fastConfiguration, paths: profilePaths, backend: .nfs, help: profileHelp,
            mountPath: directory.path, logURL: mountFixture.appendingPathComponent("rclone.log"),
            diskSpaceTotal: 5_000_000_000_000, username: "fixture", password: "fixture-only"
        )
        func profileValue(_ flag: String) -> String? {
            guard let index = profile.firstIndex(of: flag), index + 1 < profile.count else { return nil }
            return profile[index + 1]
        }
        expect(profile[2] == "nfsmount" && profileValue("--rc-addr") == "127.0.0.1:0", "Mount profile selects NFS and an OS-assigned loopback port")
        let fixedProfile = [
            ("--dir-cache-time", "9999h"), ("--poll-interval", "15s"), ("--attr-timeout", "1h"),
            ("--vfs-cache-mode", "full"), ("--vfs-write-back", "5s"),
            ("--vfs-read-chunk-size", "16M"), ("--vfs-read-chunk-size-limit", "256M"),
            ("--vfs-read-ahead", "64M"), ("--vfs-read-wait", "20ms"), ("--buffer-size", "32M"),
            ("--vfs-cache-max-size", "10G"), ("--vfs-cache-max-age", "1h"),
            ("--drive-pacer-min-sleep", "10ms"), ("--drive-pacer-burst", "200"),
            ("--drive-chunk-size", "64M"), ("--vfs-disk-space-total-size", "5000000000000B")
        ]
        for (flag, expected) in fixedProfile {
            expect(profileValue(flag) == expected, "Mount profile retains \(flag) \(expected)")
        }
        expect(profile.contains("--noappledouble") && profile.contains("--noapplexattr"), "Mount profile includes only advertised canonical Apple flags")
        let unsupported = MountArgumentsBuilder.build(
            config: StreamConfig(), paths: profilePaths, backend: .nfs, help: "",
            mountPath: directory.path, logURL: mountFixture.appendingPathComponent("rclone.log"),
            diskSpaceTotal: nil, username: "fixture", password: "fixture-only"
        )
        expect(!unsupported.contains("--noappledouble") && !unsupported.contains("--noapplexattr"), "Mount profile omits unadvertised Apple flags")
    }

}


private actor RetryProbe {
    private let failures: Int
    private let error: RcloneRCError
    private var attempts = 0
    private var delays: [TimeInterval] = []

    init(failures: Int, error: RcloneRCError) {
        self.failures = failures
        self.error = error
    }
    func next() throws -> Int {
        attempts += 1
        if attempts <= failures { throw error }
        return 42
    }
    func sleep(_ delay: TimeInterval) { delays.append(delay) }
    func snapshot() -> (attempts: Int, delays: [TimeInterval]) { (attempts, delays) }
}
