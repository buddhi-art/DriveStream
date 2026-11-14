import CryptoKit
import Darwin
import Foundation

/// All credentials are synthetic; the injected store never reads/writes Keychain.
@MainActor
final class FixtureCredentials: RcloneCredentialStore {
    var values: [String: String] = [:]
    var failOnceFor: String?
    var writes = 0
    func save(_ secret: String, for account: String) throws {
        writes += 1
        if failOnceFor == account { failOnceFor = nil; throw CocoaError(.fileWriteUnknown) }
        values[account] = secret
    }
    func readString(for account: String) throws -> String? { values[account] }
    func delete(for account: String) throws {
        writes += 1
        if failOnceFor == account { failOnceFor = nil; throw CocoaError(.fileWriteUnknown) }
        values.removeValue(forKey: account)
    }
}

@main
@MainActor
struct SecurityRegressionTests {
    static var checks = 0
    static let password = "  synthetic\r\ncrypt\0password 😺\n\t "
    static let salt = " \r\nsynthetic-salt\0雪\n "
    static let inputs = ["", "potato", " leading and trailing  ", "\0abc\0", "\r\n\nline1\nline2\r\n", password, String(repeating: "雪😺", count: 80)]
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "SecurityRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
        print("PASS: " + message)
    }

    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--config" { try runFixtureHelper(); return }
        let root = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-security-tests-")
        defer { ServiceFileSafety.removeTemporaryDirectory(root, prefix: "DriveStream-security-tests-") }
        try environmentPolicy()
        try obscurationVectors()
        try privateINI()
        try await runnerEnvironment()
        try await configTransactions(root: root)
        if CommandLine.arguments.count > 1 { try await interoperability(root: root) }
        else { print("SKIP: official rclone interoperability (supply --rclone and --rclone-sha256)") }
        print("ALL SECURITY REGRESSIONS PASSED (\(checks) checks)")
    }

    static func environmentPolicy() throws {
        let poison = ["PATH": "/tmp/untrusted:.", "HOME": "/tmp/forged-home", "TMPDIR": "/tmp/forged-temp",
                      "LANG": "forged", "LC_ALL": "forged", "DYLD_INSERT_LIBRARIES": "payload", "DYLD_LIBRARY_PATH": "payload",
                      "AWS_ACCESS_KEY_ID": "fake-aws", "AWS_SECRET_ACCESS_KEY": "fake-aws-secret", "AWS_SESSION_TOKEN": "fake-token",
                      "OPENAI_API_KEY": "fake-api", "GOOGLE_APPLICATION_CREDENTIALS": "fake-file", "TOKEN": "fake-token",
                      "RCLONE_CONFIG": "/tmp/rogue", "RCLONE_DRIVE_CLIENT_SECRET": "inherited-secret", "RCLONE_RC_PASS": "inherited-rc-secret", "RCLONE_RC_NO_AUTH": "true",
                      "HTTP_PROXY": "http://proxy.example:8080", "https_proxy": "http://secure-proxy.example:8080", "NO_PROXY": "localhost,127.0.0.1",
                      "ALL_PROXY": "socks5://unsupported", "REQUEST_METHOD": "GET"]
        let env = ProcessLaunchEnvironment.make(inherited: poison)
        try expect(env["PATH"] == ProcessLaunchEnvironment.trustedPath && !env["PATH"]!.contains("/tmp"), "PATH is deterministic and never inherits cwd/untrusted entries")
        try expect(env["HOME"]?.hasPrefix("/") == true && env["HOME"] != poison["HOME"], "HOME uses the real account directory")
        try expect(env["TMPDIR"]?.hasPrefix("/") == true && env["TMPDIR"] != poison["TMPDIR"], "TMPDIR uses Darwin's real per-user temp directory")
        try expect(env["LANG"] == "en_US.UTF-8" && env["LC_CTYPE"] == "en_US.UTF-8" && env["LC_ALL"] == nil, "installed UTF-8 locale does not inherit arbitrary locale overrides")
        for key in poison.keys.sorted() where !["PATH", "HOME", "TMPDIR", "LANG"].contains(key) && !ProcessLaunchEnvironment.proxyKeys.contains(key) {
            try expect(env[key] == nil, "inherited \(key) is absent")
        }
        try expect(env["HTTP_PROXY"] == poison["HTTP_PROXY"] && env["https_proxy"] == poison["https_proxy"] && env["NO_PROXY"] == poison["NO_PROXY"], "only documented Go HTTP proxy spellings cross the boundary")
        let overrides = ProcessLaunchEnvironment.make(inherited: poison, overrides: [
            "PATH": "/tmp/override", "HOME": "/tmp/override", "DYLD_INSERT_LIBRARIES": "payload", "RCLONE_CONFIG": "rogue",
            "RCLONE_RC_NO_AUTH": "true", "AWS_SECRET_ACCESS_KEY": "fake", "RCLONE_DRIVE_CLIENT_ID": "explicit-client",
            "RCLONE_DRIVE_CLIENT_SECRET": "explicit-secret", "RCLONE_RC_PASS": "explicit-rc-secret", "HTTP_PROXY": "", "NO_PROXY": "loopback"])
        try expect(overrides["PATH"] == env["PATH"] && overrides["HOME"] == env["HOME"], "config overrides cannot replace trusted launch identity or PATH")
        try expect(overrides["RCLONE_CONFIG"] == nil && overrides["DYLD_INSERT_LIBRARIES"] == nil && overrides["AWS_SECRET_ACCESS_KEY"] == nil && overrides["RCLONE_RC_NO_AUTH"] == nil, "arbitrary credential/loader/rclone overrides are rejected")
        try expect(overrides["RCLONE_DRIVE_CLIENT_ID"] == "explicit-client" && overrides["RCLONE_DRIVE_CLIENT_SECRET"] == "explicit-secret", "explicit OAuth credential override is deliberately allowlisted")
        try expect(overrides["RCLONE_RC_PASS"] == "explicit-rc-secret", "explicit mount RC password override is allowlisted without inheritance")
        try expect(overrides["HTTP_PROXY"] == "" && overrides["NO_PROXY"] == "loopback", "supported proxy overrides can deliberately clear/replace inherited values")
        let invalid = ProcessLaunchEnvironment.make(inherited: ["HTTP_PROXY": "bad\nproxy"], overrides: ["RCLONE_DRIVE_CLIENT_SECRET": "bad\0secret", "HTTPS_PROXY": "bad\rproxy"])
        try expect(invalid["HTTP_PROXY"] == nil && invalid["HTTPS_PROXY"] == nil && invalid["RCLONE_DRIVE_CLIENT_SECRET"] == nil, "control-character environment values are rejected before launch")
    }

    static func obscurationVectors() throws {
        // Official upstream obscure_test.go vectors, not generated by this implementation.
        // https://github.com/rclone/rclone/blob/v1.75.2/fs/config/obscure/obscure_test.go
        for (plain, iv, encoded) in [("", "aaaaaaaaaaaaaaaa", "YWFhYWFhYWFhYWFhYWFhYQ"),
                                      ("potato", "aaaaaaaaaaaaaaaa", "YWFhYWFhYWFhYWFhYWFhYXMaGgIlEQ"),
                                      ("potato", "bbbbbbbbbbbbbbbb", "YmJiYmJiYmJiYmJiYmJiYp3gcEWbAw")] {
            try expect(try RcloneObscuration.obscure(plain, iv: Data(iv.utf8)) == encoded, "AES-CTR matches official fixed rclone vector")
            try expect(try RcloneObscuration.reveal(encoded) == plain, "existing official obscured values remain readable")
        }
        for (index, input) in inputs.enumerated() {
            let obscured = try RcloneObscuration.obscure(input)
            try expect(try Data(RcloneObscuration.reveal(obscured).utf8) == Data(input.utf8), "exact UTF-8 bytes survive obscuration roundtrip fixture \(index)")
            try expect(!obscured.contains("=") && !obscured.contains("+") && !obscured.contains("/"), "rclone raw URL base64 framing fixture \(index)")
        }
        try expect(try RcloneObscuration.obscure(password) != RcloneObscuration.obscure(password), "production obscuration uses fresh random IVs")
        for invalid in ["", "aGVsbG8", "bad*base64", "YWFhYWFhYWFhYWFhYWFhYQ=", "a"] {
            do { _ = try RcloneObscuration.reveal(invalid); throw NSError(domain: "ExpectedFailure", code: 1) }
            catch is RcloneObscuration.Failure { checks += 1; print("PASS: malformed obscured value rejected") }
        }
    }

    static func privateINI() throws {
        let prefix = "# untouched comment\r\n[unrelated]\r\ntype = local\r\noption =  keep ; inline text \r\n\r\n"
        let original = Data((prefix + "[crypt]\n# keep crypt setting\nfilename_encryption = off\ncustom = untouched\npassword = old\npassword2 = oldsalt\n\n[tail]\ntype = local\n").utf8)
        let updated = try RclonePrivateConfig.updating(original, section: "crypt", options: ["password": "new", "password2": nil])
        let contents = String(decoding: updated, as: UTF8.self)
        try expect(contents.hasPrefix(prefix) && contents.hasSuffix("[tail]\ntype = local\n"), "targeted crypt INI writer preserves other remotes byte-for-byte")
        try expect(contents.contains("filename_encryption = off\ncustom = untouched") && contents.contains("# keep crypt setting"), "targeted writer preserves existing crypt options and comments")
        try expect(contents.contains("password = new") && !contents.contains("password2"), "explicit nil removes a stale salt without config CLI output")
        for data in [Data("RCLONE_ENCRYPT_V0:\nsecret".utf8), Data("# Encrypted rclone configuration File\n\nRCLONE_ENCRYPT_V0:\nsecret".utf8), Data("[crypt]\ntype=crypt\n[crypt]\ntype=crypt\n".utf8), Data([0xff])] {
            do { _ = try RclonePrivateConfig.updating(data, section: "crypt", options: ["password": "new"]); throw NSError(domain: "ExpectedFailure", code: 2) }
            catch is RcloneConfigError { checks += 1; print("PASS: unsupported/ambiguous INI update rejected without rewrite") }
        }
    }

    static func runnerEnvironment() async throws {
        setenv("DRIVESTREAM_TEST_INHERITED_TOKEN", "synthetic-leak", 1)
        defer { unsetenv("DRIVESTREAM_TEST_INHERITED_TOKEN") }
        let result = try await CommandRunner.run(executable: "/usr/bin/env", environment: ["RCLONE_CONFIG": "/tmp/rogue", "DYLD_INSERT_LIBRARIES": "payload", "RCLONE_DRIVE_CLIENT_SECRET": "explicit-fixture", "RCLONE_RC_PASS": "explicit-rc-fixture"])
        try expect(!result.standardOutput.contains("synthetic-leak") && !result.standardOutput.contains("RCLONE_CONFIG=") && !result.standardOutput.contains("DYLD_INSERT"), "actual CommandRunner child sees no inherited tokens or disallowed overrides")
        try expect(result.standardOutput.contains("RCLONE_DRIVE_CLIENT_SECRET=explicit-fixture"), "actual helper receives only an explicitly supplied OAuth credential")
        try expect(result.standardOutput.contains("RCLONE_RC_PASS=explicit-rc-fixture") && !result.arguments.contains("explicit-rc-fixture"), "actual helper receives explicit RC password without argv transport")
        let input = "  stdin\n\r\0雪  "
        let roundtrip = try await CommandRunner.run(executable: "/usr/bin/tee", input: input)
        try expect(Data(roundtrip.standardOutput.utf8) == Data(input.utf8) && roundtrip.arguments.isEmpty, "private stdin preserves exact bytes without credential argv")
    }

    static func configTransactions(root: URL) async throws {
        let paths = DriveStreamPaths(applicationSupportDirectory: root.appendingPathComponent("support"), homeDirectory: root.appendingPathComponent("home"))
        try paths.prepareFileSystem()
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: paths.rcloneBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.rcloneBinary.path)
        let credentials = FixtureCredentials()
        credentials.values = [KeychainAccountName.cryptPassword: "previous-password", KeychainAccountName.cryptSaltPassword: "previous-salt", KeychainAccountName.googleClientSecret: "previous-google"]
        let service = RcloneConfigService(paths: paths, credentialStore: credentials)
        let original = Data("# original private config\n[drive]\ntype = local\ncustom = keep\n\n[encrypted]\ntype = crypt\nremote = drive:existing-folder\nfilename_encryption = off\ndirectory_name_encryption = false\npassword = old-obscured\npassword2 = old-obscured-salt\ncustom = preserved\n".utf8)
        try ServiceFileSafety.atomicWrite(original, to: paths.configFile)
        let oldKeys = credentials.values
        try setFixture(paths, ["fail": "lsf"])
        do { _ = try await service.configureCrypt(remoteName: "drive", cryptRemoteName: "encrypted", password: password, saltPassword: salt); throw NSError(domain: "ExpectedFailure", code: 3) }
        catch is RcloneConfigError { checks += 1; print("PASS: crypt verification failure is reported") }
        try expect(try Data(contentsOf: paths.configFile) == original && credentials.values == oldKeys && credentials.writes == 0, "failed candidate listing leaves original config and Keychain untouched")
        let failedCapture = try captures(paths).last!
        try expect((failedCapture["arguments"] as? [String])?.contains(password) == false && !(failedCapture["arguments"] as! [String]).contains(where: { $0.contains("old-obscured") }), "crypt helper argv contains neither plaintext nor reversibly obscured keys")
        try expect(failedCapture["configMode"] as? Int == 0o600 && failedCapture["directoryMode"] as? Int == 0o700, "crypt candidate is private from creation")
        try expect(!FileManager.default.fileExists(atPath: failedCapture["configPath"] as! String), "failed crypt candidate is cleaned up")

        try setFixture(paths, [:])
        credentials.failOnceFor = KeychainAccountName.cryptSaltPassword
        do { _ = try await service.configureCrypt(remoteName: "drive", cryptRemoteName: "encrypted", password: password, saltPassword: salt); throw NSError(domain: "ExpectedFailure", code: 4) }
        catch is RcloneConfigError { checks += 1; print("PASS: partial credential write failure is reported") }
        try expect(try Data(contentsOf: paths.configFile) == original && credentials.values == oldKeys, "partial crypt credential failure restores all previous keys and exact config bytes")

        let profile = try await service.configureCrypt(remoteName: "drive", cryptRemoteName: "encrypted", password: password, saltPassword: salt)
        try expect(profile.isCrypt && credentials.values[KeychainAccountName.cryptPassword] == password && credentials.values[KeychainAccountName.cryptSaltPassword] == salt, "crypt setup commits exact multiline/NUL/space keys after successful verification")
        let config = try String(contentsOf: paths.configFile, encoding: .utf8)
        let saved = parseValues(config, section: "encrypted")
        try expect(try Data(RcloneObscuration.reveal(saved["password"]!).utf8) == Data(password.utf8) && Data(RcloneObscuration.reveal(saved["password2"]!).utf8) == Data(salt.utf8), "private config keys reveal to the exact original UTF-8 bytes")
        try expect(saved["filename_encryption"] == "off" && saved["directory_name_encryption"] == "false" && saved["remote"] == "drive:existing-folder" && saved["custom"] == "preserved" && config.contains("custom = keep"), "crypt updates preserve existing root paths, encryption modes/settings and other remotes")
        try expect((try FileManager.default.attributesOfItem(atPath: paths.configFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "published config remains mode 0600")
        _ = try await service.configureCrypt(remoteName: "drive", cryptRemoteName: "encrypted", password: password, saltPassword: "")
        try expect(!((try String(contentsOf: paths.configFile, encoding: .utf8)).contains("password2")) && credentials.values[KeychainAccountName.cryptSaltPassword] == nil, "empty salt removes stale config and Keychain values")

        let beforeConcurrency = try Data(contentsOf: paths.configFile)
        let keysBeforeConcurrency = credentials.values
        try setFixture(paths, ["changeOriginal": paths.configFile.path])
        do { _ = try await service.configureCrypt(remoteName: "drive", cryptRemoteName: "encrypted", password: password, saltPassword: salt); throw NSError(domain: "ExpectedFailure", code: 7) }
        catch is RcloneConfigError { checks += 1; print("PASS: concurrent external config update rejects candidate publication") }
        try expect(try Data(contentsOf: paths.configFile) == beforeConcurrency + Data("# external-token-refresh\n".utf8) && credentials.values == keysBeforeConcurrency, "external config refresh is not overwritten and credentials remain unchanged")

        try setFixture(paths, ["delay": "lsf"])
        let capturesBeforeDelay = try captures(paths).count
        let activeChange = Task { try await service.configureCrypt(remoteName: "drive", cryptRemoteName: "encrypted", password: password, saltPassword: salt) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (try captures(paths).count) == capturesBeforeDelay && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try expect(try captures(paths).count > capturesBeforeDelay, "fixture signals that crypt verification is in flight")
        do { try service.writeDriveRemote(remoteName: "blocked", token: "synthetic", clientID: "", clientSecret: ""); throw NSError(domain: "ExpectedFailure", code: 8) }
        catch is RcloneConfigError { checks += 1; print("PASS: synchronous writer is blocked by async mutation guard") }
        activeChange.cancel()
        do { _ = try await activeChange.value; throw NSError(domain: "ExpectedFailure", code: 9) }
        catch is CancellationError { checks += 1; print("PASS: cancelled crypt verification propagates cancellation") }
        try expect(try Data(contentsOf: paths.configFile) == beforeConcurrency + Data("# external-token-refresh\n".utf8) && credentials.values == keysBeforeConcurrency, "cancelled verification leaves live config and keys intact")

        let beforeGoogle = try Data(contentsOf: paths.configFile)
        let beforeGoogleKeys = credentials.values
        try setFixture(paths, ["fail": "about"])
        do { _ = try await service.connectGoogleDrive(remoteName: "google", clientID: "fixture-client", clientSecret: "fixture-oauth-secret"); throw NSError(domain: "ExpectedFailure", code: 5) }
        catch is RcloneConfigError { checks += 1; print("PASS: OAuth candidate verification failure is reported") }
        try expect(try Data(contentsOf: paths.configFile) == beforeGoogle && credentials.values == beforeGoogleKeys, "failed OAuth verification leaves active config and old secret intact")
        let oauthCapture = try captures(paths).last(where: { ($0["arguments"] as? [String])?.contains("authorize") == true })!
        let oauthArgs = oauthCapture["arguments"] as! [String]
        let oauthEnv = oauthCapture["environment"] as! [String: String]
        try expect(oauthArgs.count == 4 && oauthArgs.suffix(2) == ["authorize", "drive"] && !oauthArgs.contains("fixture-oauth-secret"), "custom OAuth authorization has backend-only non-secret argv")
        try expect(oauthEnv["RCLONE_DRIVE_CLIENT_ID"] == "fixture-client" && oauthEnv["RCLONE_DRIVE_CLIENT_SECRET"] == "fixture-oauth-secret", "custom OAuth uses supported explicitly scoped backend environment credentials")
        try expect(oauthCapture["configMode"] as? Int == 0o600 && oauthCapture["directoryMode"] as? Int == 0o700 && oauthCapture["configContents"] as? String == "", "OAuth helper operates on a private empty temporary config")
        try expect(!FileManager.default.fileExists(atPath: oauthCapture["configPath"] as! String), "OAuth temporary config is removed after helper completion")

        try setFixture(paths, [:])
        credentials.failOnceFor = KeychainAccountName.googleClientSecret
        do { _ = try await service.connectGoogleDrive(remoteName: "google", clientID: "fixture-client", clientSecret: "fixture-oauth-secret"); throw NSError(domain: "ExpectedFailure", code: 6) }
        catch is RcloneConfigError { checks += 1; print("PASS: OAuth credential commit failure is reported") }
        try expect(try Data(contentsOf: paths.configFile) == beforeGoogle && credentials.values == beforeGoogleKeys, "OAuth credential failure restores prior secret/config")
        let connected = try await service.connectGoogleDrive(remoteName: "google", clientID: "fixture-client", clientSecret: "fixture-oauth-secret")
        try expect(connected.profile.isDrive && connected.profile.hasToken && connected.usesCustomOAuth && credentials.values[KeychainAccountName.googleClientSecret] == "fixture-oauth-secret", "synthetic OAuth flow verifies and commits without browser or user Keychain")
        let beforeAuthFailure = try Data(contentsOf: paths.configFile)
        let keysBeforeAuthFailure = credentials.values
        try setFixture(paths, ["fail": "authorize"])
        do { _ = try await service.connectGoogleDrive(remoteName: "google", clientID: "fixture-client", clientSecret: "fixture-oauth-secret"); throw NSError(domain: "ExpectedFailure", code: 10) }
        catch let error as RcloneConfigError {
            try expect(!error.localizedDescription.contains("MUST NOT BE RENDERED"), "authorization failure errors omit captured helper secrets")
        }
        try expect(try Data(contentsOf: paths.configFile) == beforeAuthFailure && credentials.values == keysBeforeAuthFailure, "failed authorization leaves config and credentials unchanged")
        try setFixture(paths, [:])
        let defaultConnection = try await service.connectGoogleDrive(remoteName: "google", clientID: "", clientSecret: "")
        let defaultConfig = try String(contentsOf: paths.configFile, encoding: .utf8)
        let defaultCapture = try captures(paths).last(where: { ($0["arguments"] as? [String])?.contains("authorize") == true })!
        let defaultEnv = defaultCapture["environment"] as! [String: String]
        try expect(!defaultConnection.usesCustomOAuth && credentials.values[KeychainAccountName.googleClientSecret] == nil && !defaultConfig.contains("client_secret") && !defaultConfig.contains("client_id"), "default OAuth clears stale custom config and Keychain credentials")
        try expect(defaultEnv["RCLONE_DRIVE_CLIENT_ID"] == nil && defaultEnv["RCLONE_DRIVE_CLIENT_SECRET"] == nil, "default OAuth helper inherits no custom client environment credentials")

        let finalCaptures = try captures(paths)
        try expect(finalCaptures.allSatisfy { capture in
            let args = capture["arguments"] as! [String]
            return !args.contains(password) && !args.contains(salt) && !args.contains("fixture-oauth-secret") && !args.contains("obscure") && !args.contains("create") && !args.contains("update")
        }, "every fixture helper invocation avoids plaintext, obscured-key, and OAuth-secret argv")
    }

    static func parseValues(_ contents: String, section: String) -> [String: String] {
        var active = false
        var result: [String: String] = [:]
        for raw in contents.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { active = line == "[\(section)]"; continue }
            guard active, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            result[String(line[..<equals]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func setFixture(_ paths: DriveStreamPaths, _ options: [String: String]) throws {
        try ServiceFileSafety.atomicWrite(JSONSerialization.data(withJSONObject: options), to: paths.binDirectory.appendingPathComponent("fixture.json"))
    }
    static func captures(_ paths: DriveStreamPaths) throws -> [[String: Any]] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: paths.binDirectory.appendingPathComponent("captures.json"))) as! [[String: Any]]
    }

    /// This same test executable doubles as a deterministic rclone fixture. Its
    /// control data lives next to the private copied executable, not in extra env.
    static func runFixtureHelper() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 4 else { exit(9) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let config = URL(fileURLWithPath: args[1])
        let options = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("fixture.json"))) as! [String: String]
        let log = directory.appendingPathComponent("captures.json")
        var records = (try? JSONSerialization.jsonObject(with: Data(contentsOf: log))) as? [[String: Any]] ?? []
        records.append(["arguments": args, "environment": ProcessInfo.processInfo.environment,
                        "configPath": config.path, "configContents": try String(contentsOf: config, encoding: .utf8),
                        "configMode": (try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as! NSNumber).intValue,
                        "directoryMode": (try FileManager.default.attributesOfItem(atPath: config.deletingLastPathComponent().path)[.posixPermissions] as! NSNumber).intValue])
        try ServiceFileSafety.atomicWrite(JSONSerialization.data(withJSONObject: records), to: log)
        if options["delay"] == args[2] { Thread.sleep(forTimeInterval: 1) }
        if let originalPath = options["changeOriginal"], args[2] == "lsf" {
            let original = URL(fileURLWithPath: originalPath)
            try ServiceFileSafety.atomicWrite(try Data(contentsOf: original) + Data("# external-token-refresh\n".utf8), to: original)
        }
        if options["fail"] == args[2] {
            try FileHandle.standardError.write(contentsOf: Data("synthetic helper secret MUST NOT BE RENDERED\n".utf8))
            exit(7)
        }
        switch args[2] {
        case "authorize": print(#"{"access_token":"synthetic-token","refresh_token":"synthetic-refresh"}"#)
        case "about": print(#"{"total":1000,"used":20,"free":980}"#)
        case "config": print(#"{"email":"synthetic@example.invalid","name":"Fixture"}"#)
        case "lsf": break
        default: exit(8)
        }
    }

    static func interoperability(root: URL) async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4, args[0] == "--rclone", args[2] == "--rclone-sha256", args[1].hasPrefix("/"),
              args[3].count == 64, args[3].allSatisfy({ $0.isHexDigit }) else {
            throw NSError(domain: "InteroperabilityUsage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use --rclone /absolute/official/binary --rclone-sha256 VERIFIED_BINARY_SHA256 (after verifying its official archive checksum)."])
        }
        let executable = args[1]
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: executable))).map { String(format: "%02x", $0) }.joined()
        try expect(digest == args[3].lowercased(), "optional official rclone binary checksum matches caller-verified SHA256")
        let config = root.appendingPathComponent("interop.conf")
        try ServiceFileSafety.createPrivateFile(config)
        let version = try await CommandRunner.run(executable: executable, arguments: ["--config", config.path, "version"])
        print("INTEROPERABILITY: " + version.standardOutput.components(separatedBy: "\n").first!)
        for input in ["potato", " leading and trailing  ", "\0abc\0", String(repeating: "雪😺", count: 80)] {
            let result = try await CommandRunner.run(executable: executable, arguments: ["--config", config.path, "obscure", "-"], input: input + "\n")
            let official = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            try expect(try Data(RcloneObscuration.reveal(official).utf8) == Data(input.utf8), "Swift reveals official rclone obscuration without plaintext argv")
            let swift = try RcloneObscuration.obscure(input)
            let contents = "[swift]\ntype = crypt\nremote = /\npassword = \(swift)\n[official]\ntype = crypt\nremote = /\npassword = \(official)\n"
            try ServiceFileSafety.atomicWrite(Data(contents.utf8), to: config)
            let a = try await CommandRunner.run(executable: executable, arguments: ["--config", config.path, "cryptdecode", "--reverse", "swift:", "synthetic-file.txt"])
            let b = try await CommandRunner.run(executable: executable, arguments: ["--config", config.path, "cryptdecode", "--reverse", "official:", "synthetic-file.txt"])
            try expect(a.standardOutput == b.standardOutput, "official crypt derives identical cipher keys from Swift and official obscuration")
        }
        try await multilineInteroperability(executable: executable, config: config)
    }

    /// Official obscure CLI reads only one stdin line. Exercise CR/LF/NUL using
    /// its supported core/obscure RC API with JSON bodies, NOT secret argv/flags.
    /// The optional server binds only loopback, holds synthetic data, and is joined
    /// after cancellation on both success and failure. No browser/OAuth/Google flow.
    static func multilineInteroperability(executable: String, config: URL) async throws {
        let port = try unusedLoopbackPort()
        let server = Task {
            try await CommandRunner.run(executable: executable, arguments: ["--config", config.path,
                "rcd", "--rc-addr", "127.0.0.1:\(port)", "--rc-no-auth", "--log-level", "ERROR"], timeout: 30)
        }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [:]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var ready = false
            while ContinuousClock.now < deadline {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/core/version")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 0.3
                if let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { ready = true; break }
                try await Task.sleep(for: .milliseconds(40))
            }
            try expect(ready, "optional official RC fixture binds loopback and becomes ready")
            for (index, input) in inputs.enumerated() {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/core/obscure")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 2
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["clear": input])
                let (data, response) = try await session.data(for: request)
                try expect((response as? HTTPURLResponse)?.statusCode == 200, "official core/obscure accepts JSON body fixture \(index)")
                let object = try JSONSerialization.jsonObject(with: data) as! [String: String]
                let official = object["obscured"]!
                try expect(try Data(RcloneObscuration.reveal(official).utf8) == Data(input.utf8), "Swift reveals exact official CR/LF/NUL/Unicode bytes fixture \(index)")
                if !input.isEmpty {
                    let swift = try RcloneObscuration.obscure(input)
                    let swiftSalt = try RcloneObscuration.obscure(salt)
                    // Distinct IVs, same full plaintext bytes => same derived cipher.
                    let officialSalt = try RcloneObscuration.obscure(salt, iv: Data(repeating: 0x62, count: 16))
                    let contents = "[swift]\ntype = crypt\nremote = /\npassword = \(swift)\npassword2 = \(swiftSalt)\n[official]\ntype = crypt\nremote = /\npassword = \(official)\npassword2 = \(officialSalt)\n"
                    try ServiceFileSafety.atomicWrite(Data(contents.utf8), to: config)
                    let a = try await CommandRunner.run(executable: executable, arguments: ["--config", config.path, "cryptdecode", "--reverse", "swift:", "synthetic-file.txt"])
                    let b = try await CommandRunner.run(executable: executable, arguments: ["--config", config.path, "cryptdecode", "--reverse", "official:", "synthetic-file.txt"])
                    try expect(a.standardOutput == b.standardOutput, "official crypt accepts exact Swift/official multiline key bytes fixture \(index)")
                }
            }
        } catch {
            server.cancel()
            _ = try? await server.value
            throw error
        }
        server.cancel()
        _ = try? await server.value
        checks += 1
        print("PASS: optional official RC server shutdown is joined before returning")
    }

    static func unusedLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { throw POSIXError(.EIO) }
        return UInt16(bigEndian: address.sin_port)
    }
}
