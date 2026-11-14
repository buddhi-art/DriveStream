import Foundation

// MARK: - Models

struct RcloneRemoteProfile: Equatable, Sendable {
    var name: String
    var type: String?
    var clientID: String?
    var hasClientSecret: Bool
    var hasToken: Bool
    var cryptUnderlyingRemote: String?
    var sharedDriveID: String? = nil
    var cacheNamespace: String? = nil

    var isCrypt: Bool { type == "crypt" }
    var isDrive: Bool { type == "drive" }
}

struct GoogleAccountInfo: Equatable, Sendable {
    var email: String?
    var displayName: String?

    var displayLabel: String? {
        if let email, !email.isEmpty { return email }
        if let displayName, !displayName.isEmpty { return displayName }
        return nil
    }
}

struct GoogleConnectionResult: Equatable, Sendable {
    var remoteName: String
    var profile: RcloneRemoteProfile
    var about: RcloneAbout?
    var account: GoogleAccountInfo?
    var usesCustomOAuth: Bool
}

enum RcloneConfigError: LocalizedError {
    case binaryMissing
    case invalidConfiguration(String)
    case invalidClientCredentials(String)
    case authorizationFailed(String)
    case authorizationTimedOut
    case tokenNotFound(String)
    case remoteCreationFailed(String)
    case verificationFailed(String)
    case remoteNotFound(String)
    case cryptSetupFailed(String)
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "The rclone binary is not installed yet. DriveStream will download it automatically."
        case .invalidConfiguration(let message):
            return message
        case .invalidClientCredentials(let message):
            return message
        case .authorizationFailed(let message):
            return "Google authorization failed: \(message)"
        case .authorizationTimedOut:
            return "Google authorization timed out. Complete the sign-in in your browser and try again."
        case .tokenNotFound(let output):
            return "Google sign-in completed, but DriveStream could not read the OAuth token. \(output)"
        case .remoteCreationFailed(let message):
            return "Could not save the Google Drive remote: \(message)"
        case .verificationFailed(let message):
            return "Google Drive could not be verified: \(message)"
        case .remoteNotFound(let name):
            return "The rclone remote “\(name)” does not exist."
        case .cryptSetupFailed(let message):
            return "Could not configure encryption: \(message)"
        case .keychain(let message):
            return "Could not save the secret in the macOS Keychain: \(message)"
        }
    }
}

// MARK: - Service

/// Owns DriveStream's private rclone configuration file.
///
/// Google tokens live in the mode-0600 private config. Crypt passwords also have a
/// Keychain copy; the config contains reversibly obscured passwords, NOT encryption
/// of the configuration. Treat both the config and Keychain values as secrets.
@MainActor
final class RcloneConfigService {
    let paths: DriveStreamPaths
    let keychain: KeychainHelper
    private let credentialStore: any RcloneCredentialStore

    // Actor reentrancy must not let two async config writers run simultaneously.
    private var mutationInProgress = false

    private func beginMutation() throws {
        try Task.checkCancellation()
        guard !mutationInProgress else {
            throw RcloneConfigError.invalidConfiguration("Another configuration change is in progress.")
        }
        mutationInProgress = true
    }

    init(paths: DriveStreamPaths, keychain: KeychainHelper = .shared) {
        self.paths = paths
        self.keychain = keychain
        self.credentialStore = keychain
    }

    /// Internal dependency injection for offline tests; never uses the user Keychain.
    init(paths: DriveStreamPaths, credentialStore: any RcloneCredentialStore) {
        self.paths = paths
        self.keychain = .shared
        self.credentialStore = credentialStore
    }

    // MARK: Local configuration inspection

    func remoteExists(_ name: String) -> Bool {
        guard let sections = try? readSections() else { return false }
        return sections[name] != nil
    }

    func configuredRemoteNames() -> [String] {
        ((try? readSections()) ?? [:]).keys.sorted()
    }

    func profile(for name: String) -> RcloneRemoteProfile? {
        guard let sections = try? readSections(), let values = sections[name] else { return nil }
        return Self.profile(name: name, values: values)
    }

    nonisolated static func profile(in data: Data, for name: String) -> RcloneRemoteProfile? {
        guard let contents = String(data: data, encoding: .utf8),
              let values = parseSections(contents)[name] else { return nil }
        return profile(name: name, values: values)
    }

    nonisolated private static func profile(name: String, values: [String: String]) -> RcloneRemoteProfile {
        RcloneRemoteProfile(
            name: name,
            type: values["type"],
            clientID: values["client_id"].flatMap { $0.isEmpty ? nil : $0 },
            hasClientSecret: !(values["client_secret"] ?? "").isEmpty,
            hasToken: !(values["token"] ?? "").isEmpty,
            cryptUnderlyingRemote: values["remote"],
            sharedDriveID: values["team_drive"].flatMap { $0.isEmpty ? nil : $0 },
            cacheNamespace: values[RcloneDriveRootService.cacheNamespaceKey].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    func storedClientSecret() -> String? {
        try? credentialStore.readString(for: KeychainAccountName.googleClientSecret)
    }

    // MARK: Mount root

    func sharedDrives(remoteName: String) async throws -> [GoogleSharedDrive] {
        try await RcloneDriveRootService(paths: paths).sharedDrives(remoteName: remoteName)
    }

    /// The controller must first detach the mount and verify its cached writes.
    func setDriveRoot(remoteName: String, sharedDriveID: String, expectedSharedDriveID: String) async throws -> RcloneRemoteProfile {
        try beginMutation()
        defer { mutationInProgress = false }
        return try await RcloneDriveRootService(paths: paths).setDriveRoot(
            remoteName: remoteName, sharedDriveID: sharedDriveID, expectedSharedDriveID: expectedSharedDriveID
        )
    }

    // MARK: Connect Google Drive

    /// Runs rclone's OAuth loopback flow (the browser opens automatically), then saves
    /// the resulting token in DriveStream's private config. Passing an empty client ID
    /// uses rclone's built-in Google credentials; supplying a personal Desktop OAuth
    /// client avoids shared-client quota pressure during heavy Finder/4K workloads.
    func connectGoogleDrive(
        remoteName: String,
        clientID: String,
        clientSecret: String
    ) async throws -> GoogleConnectionResult {
        try beginMutation()
        defer { mutationInProgress = false }
        guard Self.validRemoteName(remoteName) else {
            throw RcloneConfigError.invalidConfiguration("The rclone remote name is invalid.")
        }
        guard FileManager.default.isExecutableFile(atPath: paths.rcloneBinary.path) else {
            throw RcloneConfigError.binaryMissing
        }
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedClientID.isEmpty && trimmedClientSecret.isEmpty {
            throw RcloneConfigError.invalidClientCredentials(
                "A custom Google OAuth Client ID also requires its Client Secret."
            )
        }
        if trimmedClientID.isEmpty && !trimmedClientSecret.isEmpty {
            throw RcloneConfigError.invalidClientCredentials(
                "A Google OAuth Client Secret was provided without a Client ID."
            )
        }
        guard Self.validINIValue(trimmedClientID), Self.validINIValue(trimmedClientSecret) else {
            throw RcloneConfigError.invalidClientCredentials("OAuth credentials must not contain control characters.")
        }
        let usesCustomOAuth = !trimmedClientID.isEmpty
        try paths.prepareFileSystem()

        let token = try await authorize(clientID: trimmedClientID, clientSecret: trimmedClientSecret)
        try Task.checkCancellation()

        let original = try Data(contentsOf: paths.configFile)
        let credentials: RcloneCredentialSnapshot
        do {
            credentials = try RcloneCredentialSnapshot(accounts: [KeychainAccountName.googleClientSecret], store: credentialStore)
        } catch {
            throw RcloneConfigError.keychain("Could not read the previous OAuth credential before making changes.")
        }
        let directory = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-google-config-")
        defer { ServiceFileSafety.removeTemporaryDirectory(directory, prefix: "DriveStream-google-config-") }
        let candidate = directory.appendingPathComponent("rclone.conf")
        // Reuse the completed authorize flow: config create would re-enter browser
        // OAuth even with a token. Verify a private direct INI candidate instead.
        let data = try Self.driveRemoteData(original, remoteName: remoteName, token: token,
            clientID: trimmedClientID, clientSecret: trimmedClientSecret)
        try ServiceFileSafety.createPrivateFile(candidate, data: data)
        let about: RcloneAbout?
        if Self.profile(in: data, for: remoteName)?.sharedDriveID != nil {
            // Shared Drives do not necessarily expose quota, including on reconnect.
            try await RcloneDriveRootService(paths: paths).verifyAccess(remoteName: remoteName, configFile: candidate)
            about = nil
        } else {
            about = try await self.about(remoteName: remoteName, configFile: candidate)
            guard about != nil else {
                throw RcloneConfigError.verificationFailed("Google Drive returned no quota information.")
            }
        }
        let account = await accountInfo(remoteName: remoteName, configFile: candidate)
        try Task.checkCancellation()
        guard try Data(contentsOf: paths.configFile) == original else {
            throw RcloneConfigError.invalidConfiguration("The config changed during Google verification. Retry the change.")
        }
        let verified = try Data(contentsOf: candidate)
        guard let contents = String(data: verified, encoding: .utf8),
              Self.parseSections(contents)[remoteName]?["type"] == "drive",
              Self.parseSections(contents)[remoteName]?["token"]?.isEmpty == false else {
            throw RcloneConfigError.remoteCreationFailed("The Google remote was not readable after verification.")
        }
        do {
            if usesCustomOAuth { try credentialStore.save(trimmedClientSecret, for: KeychainAccountName.googleClientSecret) }
            else { try credentialStore.delete(for: KeychainAccountName.googleClientSecret) }
            try ServiceFileSafety.atomicWrite(verified, to: paths.configFile)
        } catch {
            let failure = error
            try restoreConfiguration(original, credentials: credentials)
            if failure is CancellationError { throw failure }
            throw RcloneConfigError.remoteCreationFailed("The Google connection could not be saved; the previous configuration was restored.")
        }
        guard let profile = profile(for: remoteName), profile.isDrive, profile.hasToken else {
            try restoreConfiguration(original, credentials: credentials)
            throw RcloneConfigError.remoteCreationFailed("The new remote was not readable after creation; the previous configuration was restored.")
        }
        return GoogleConnectionResult(remoteName: remoteName, profile: profile, about: about,
                                      account: account, usesCustomOAuth: usesCustomOAuth)
    }

    private func authorize(clientID: String, clientSecret: String) async throws -> String {
        do {
            let result = try await RcloneOAuthAuthorization.run(
                executable: paths.rcloneBinary.path, clientID: clientID, clientSecret: clientSecret
            )
            guard let token = Self.extractTokenJSON(from: result.combinedOutput) else {
                throw RcloneConfigError.tokenNotFound(Self.sanitizedTail(result.combinedOutput))
            }
            return token
        } catch let error as CommandRunnerError {
            if case .timedOut = error { throw RcloneConfigError.authorizationTimedOut }
            throw RcloneConfigError.authorizationFailed(Self.sanitizedTail(error.localizedDescription))
        }
    }

    // MARK: Encryption

    /// Creates or updates a `crypt` remote layered over the Google Drive remote.
    /// Verify a private candidate before publishing keys/config. Obscuration preserves
    /// every UTF-8 byte and is reversible; neither plaintext nor obscured keys enter argv.
    func configureCrypt(
        remoteName: String,
        cryptRemoteName: String,
        password: String,
        saltPassword: String
    ) async throws -> RcloneRemoteProfile {
        try beginMutation()
        defer { mutationInProgress = false }
        guard Self.validRemoteName(remoteName) else {
            throw RcloneConfigError.invalidConfiguration("The rclone remote name is invalid.")
        }
        guard remoteExists(remoteName) else {
            throw RcloneConfigError.remoteNotFound(remoteName)
        }
        guard Self.validRemoteName(cryptRemoteName), cryptRemoteName != remoteName else {
            throw RcloneConfigError.invalidConfiguration("The encrypted remote name is invalid.")
        }
        guard password.count >= 8 else {
            throw RcloneConfigError.invalidConfiguration("Use an encryption password with at least 8 characters.")
        }
        if !saltPassword.isEmpty && saltPassword.count < 8 {
            throw RcloneConfigError.invalidConfiguration("Use a salt password with at least 8 characters, or leave it empty.")
        }
        guard FileManager.default.isExecutableFile(atPath: paths.rcloneBinary.path) else {
            throw RcloneConfigError.binaryMissing
        }
        try paths.prepareFileSystem()
        let original = try Data(contentsOf: paths.configFile)
        let sections = try readSections()
        let existing = sections[cryptRemoteName] ?? [:]
        guard existing.isEmpty || existing["type"] == "crypt" else {
            throw RcloneConfigError.invalidConfiguration("The encrypted remote name belongs to a different backend.")
        }
        let keys: RcloneCredentialSnapshot
        do {
            keys = try RcloneCredentialSnapshot(accounts: [KeychainAccountName.cryptPassword, KeychainAccountName.cryptSaltPassword], store: credentialStore)
        } catch {
            throw RcloneConfigError.keychain("Could not read the previous encryption credentials before making changes.")
        }
        let directory = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-crypt-")
        defer { ServiceFileSafety.removeTemporaryDirectory(directory, prefix: "DriveStream-crypt-") }
        let candidate = directory.appendingPathComponent("rclone.conf")
        do {
            let obscured = try RcloneObscuration.obscure(password)
            let obscuredSalt = saltPassword.isEmpty ? nil : try RcloneObscuration.obscure(saltPassword)
            let underlyingRemote = existing["remote"].flatMap { $0.hasPrefix("\(remoteName):") ? $0 : nil } ?? "\(remoteName):"
            let data = try RclonePrivateConfig.updating(original, section: cryptRemoteName, options: [
                "type": "crypt", "remote": underlyingRemote,
                // Existing encryption modes must not change: that would make stored
                // encrypted names unreadable. Defaults apply only to absent options.
                "filename_encryption": existing["filename_encryption"] ?? "standard",
                "directory_name_encryption": existing["directory_name_encryption"] ?? "true",
                "password": obscured, "password2": obscuredSalt
            ])
            try ServiceFileSafety.createPrivateFile(candidate, data: data)
            // Verify without changing the active config or Keychain. rclone may refresh
            // the candidate's Drive token; publish that refreshed private file on success.
            _ = try await CommandRunner.run(executable: paths.rcloneBinary.path,
                arguments: ["--config", candidate.path, "lsf", "\(cryptRemoteName):", "--max-depth", "1"], timeout: 60)
            try Task.checkCancellation()
            guard try Data(contentsOf: paths.configFile) == original else {
                throw RcloneConfigError.invalidConfiguration("The config changed during encryption verification. Retry the change.")
            }
            let verified = try Data(contentsOf: candidate)
            guard let contents = String(data: verified, encoding: .utf8),
                  Self.parseSections(contents)[cryptRemoteName]?["type"] == "crypt" else {
                throw RcloneConfigError.cryptSetupFailed("The encrypted remote was not readable after verification.")
            }
            // No suspension between credential writes and atomic config publication.
            // If any write fails, try every key restoration and restore exact config bytes.
            do {
                try credentialStore.save(password, for: KeychainAccountName.cryptPassword)
                if saltPassword.isEmpty { try credentialStore.delete(for: KeychainAccountName.cryptSaltPassword) }
                else { try credentialStore.save(saltPassword, for: KeychainAccountName.cryptSaltPassword) }
                try ServiceFileSafety.atomicWrite(verified, to: paths.configFile)
            } catch {
                let failure = error
                try restoreConfiguration(original, credentials: keys)
                if failure is CancellationError { throw failure }
                throw RcloneConfigError.cryptSetupFailed("The encryption change could not be saved; the previous configuration was restored.")
            }
        } catch {
            if error is CancellationError { throw error }
            if let error = error as? RcloneConfigError { throw error }
            throw RcloneConfigError.cryptSetupFailed("The encrypted remote could not be verified or saved. Helper output was omitted to protect credentials.")
        }
        guard let profile = profile(for: cryptRemoteName), profile.isCrypt else {
            // Local inspection should be infallible after validation, but still recover
            // the previous keys/config if the filesystem fails at this last boundary.
            try restoreConfiguration(original, credentials: keys)
            throw RcloneConfigError.cryptSetupFailed("The encrypted remote was not readable after creation; the previous configuration was restored.")
        }
        return profile
    }

    func removeRemote(named name: String) async throws {
        try beginMutation()
        defer { mutationInProgress = false }
        guard Self.validRemoteName(name) else {
            throw RcloneConfigError.invalidConfiguration("The rclone remote name is invalid.")
        }
        guard remoteExists(name) else { return }
        guard FileManager.default.isExecutableFile(atPath: paths.rcloneBinary.path) else {
            throw RcloneConfigError.binaryMissing
        }
        do {
            _ = try await CommandRunner.run(
                executable: paths.rcloneBinary.path,
                arguments: ["--config", paths.configFile.path, "config", "delete", name],
                timeout: 30
            )
        } catch {
            if error is CancellationError { throw error }
            throw RcloneConfigError.remoteCreationFailed(error.localizedDescription)
        }
    }

    private func restoreConfiguration(_ data: Data, credentials: RcloneCredentialSnapshot) throws {
        var failed = false
        do { try ServiceFileSafety.atomicWrite(data, to: paths.configFile) } catch { failed = true }
        do { try credentials.restore(to: credentialStore) } catch { failed = true }
        if failed {
            throw RcloneConfigError.invalidConfiguration("The previous configuration or credentials could not be fully restored. Keep your encryption recovery keys safe before retrying.")
        }
    }

    // MARK: Quota and account

    func about(remoteName: String) async throws -> RcloneAbout? {
        try await about(remoteName: remoteName, configFile: paths.configFile)
    }

    private func about(remoteName: String, configFile: URL) async throws -> RcloneAbout? {
        let name = remoteName.hasSuffix(":") ? String(remoteName.dropLast()) : remoteName
        guard Self.validRemoteName(name) else {
            throw RcloneConfigError.invalidConfiguration("The rclone remote name is invalid.")
        }
        guard FileManager.default.isExecutableFile(atPath: paths.rcloneBinary.path) else {
            throw RcloneConfigError.binaryMissing
        }
        let specifier = remoteName.hasSuffix(":") ? remoteName : "\(remoteName):"
        do {
            let result = try await CommandRunner.run(
                executable: paths.rcloneBinary.path,
                arguments: [
                    "--config", configFile.path,
                    "about", specifier, "--json"
                ],
                timeout: 45
            )
            guard let jsonObject = Self.extractJSONObject(from: result.standardOutput) else {
                throw RcloneConfigError.verificationFailed(
                    "The about response was not valid JSON: \(Self.sanitizedTail(result.combinedOutput))"
                )
            }
            do {
                return try JSONDecoder().decode(RcloneAbout.self, from: jsonObject)
            } catch {
                if error is CancellationError { throw error }
                throw RcloneConfigError.verificationFailed(error.localizedDescription)
            }
        } catch let error as RcloneConfigError {
            throw error
        } catch {
            if error is CancellationError { throw error }
            throw RcloneConfigError.verificationFailed(error.localizedDescription)
        }
    }

    func accountInfo(remoteName: String) async -> GoogleAccountInfo? {
        await accountInfo(remoteName: remoteName, configFile: paths.configFile)
    }

    private func accountInfo(remoteName: String, configFile: URL) async -> GoogleAccountInfo? {
        let validatedName = remoteName.hasSuffix(":") ? String(remoteName.dropLast()) : remoteName
        guard Self.validRemoteName(validatedName) else { return nil }
        guard FileManager.default.isExecutableFile(atPath: paths.rcloneBinary.path) else { return nil }
        let specifier = remoteName.hasSuffix(":") ? remoteName : "\(remoteName):"
        guard let result = try? await CommandRunner.run(
            executable: paths.rcloneBinary.path,
            arguments: [
                "--config", configFile.path,
                "config", "userinfo", specifier, "--json"
            ],
            timeout: 25
        ), let data = Self.extractJSONObject(from: result.standardOutput),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func stringValue(for keys: [String]) -> String? {
            for key in keys {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }

        let email = stringValue(for: ["email", "emailAddress", "userEmail", "email_address"])
        let name = stringValue(for: ["name", "displayName", "display_name", "givenName"])
        if email == nil && name == nil { return nil }
        return GoogleAccountInfo(email: email, displayName: name)
    }

    // MARK: Config file parsing and writing

    private func readSections() throws -> [String: [String: String]] {
        try paths.prepareFileSystem()
        guard FileManager.default.fileExists(atPath: paths.configFile.path) else { return [:] }
        let contents: String
        do {
            contents = try String(contentsOf: paths.configFile, encoding: .utf8)
        } catch {
            if error is CancellationError { throw error }
            throw RcloneConfigError.invalidConfiguration(
                "Could not read DriveStream's rclone config: \(error.localizedDescription)"
            )
        }
        return Self.parseSections(contents)
    }

    nonisolated private static func parseSections(_ contents: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var currentSection: String?
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                currentSection = name
                if sections[name] == nil { sections[name] = [:] }
                continue
            }
            guard let currentSection, let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                sections[currentSection, default: [:]][key] = value
            }
        }
        return sections
    }

    /// Writes or updates the Drive remote directly. This avoids rclone's interactive
    /// OAuth config state machine when a token has already been obtained. Unrelated
    /// options and other remotes (for example the crypt remote) are preserved.
    func writeDriveRemote(
        remoteName: String,
        token: String,
        clientID: String,
        clientSecret: String
    ) throws {
        guard !mutationInProgress else {
            throw RcloneConfigError.invalidConfiguration("Another configuration change is in progress.")
        }
        try writeDriveRemoteContents(remoteName: remoteName, token: token, clientID: clientID, clientSecret: clientSecret)
    }

    private func writeDriveRemoteContents(remoteName: String, token: String, clientID: String, clientSecret: String) throws {
        try Self.validateDriveCredentials(remoteName: remoteName, token: token, clientID: clientID, clientSecret: clientSecret)
        try paths.prepareFileSystem()
        let original = try Data(contentsOf: paths.configFile)
        let data = try Self.driveRemoteData(original, remoteName: remoteName, token: token, clientID: clientID, clientSecret: clientSecret)
        do { try ServiceFileSafety.atomicWrite(data, to: paths.configFile) }
        catch {
            if error is CancellationError { throw error }
            throw RcloneConfigError.remoteCreationFailed("Could not atomically write the private rclone config.")
        }
    }

    nonisolated private static func validateDriveCredentials(remoteName: String, token: String, clientID: String, clientSecret: String) throws {
        guard validRemoteName(remoteName) else {
            throw RcloneConfigError.invalidConfiguration("The rclone remote name is invalid.")
        }
        guard !token.isEmpty else { throw RcloneConfigError.remoteCreationFailed("The OAuth token was empty.") }
        guard validINIValue(token), validINIValue(clientID), validINIValue(clientSecret) else {
            throw RcloneConfigError.remoteCreationFailed("The OAuth credentials contained control characters.")
        }
    }

    nonisolated private static func driveRemoteData(_ original: Data, remoteName: String, token: String, clientID: String, clientSecret: String) throws -> Data {
        try validateDriveCredentials(remoteName: remoteName, token: token, clientID: clientID, clientSecret: clientSecret)
        return try RclonePrivateConfig.updating(original, section: remoteName, options: [
            "type": "drive", "scope": "drive", "token": token,
            "client_id": clientID.isEmpty ? nil : clientID,
            "client_secret": clientID.isEmpty ? nil : clientSecret
        ])
    }

    // MARK: JSON helpers

    /// Extracts the first complete JSON object from rclone's output.
    nonisolated static func extractJSONObject(from output: String) -> Data? {
        let text = stripANSI(output)
        guard let start = text.firstIndex(of: "{"),
              let end = matchingBrace(in: text, from: start) else { return nil }
        let candidate = String(text[start...end])
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? data
    }

    /// Extracts the OAuth token JSON produced by `rclone authorize`.
    nonisolated static func extractTokenJSON(from output: String) -> String? {
        let text = stripANSI(output)
        guard let tokenKey = text.range(of: "\"access_token\"") else { return nil }
        let prefix = text[..<tokenKey.lowerBound]
        guard let start = prefix.lastIndex(of: "{") else { return nil }
        guard let end = matchingBrace(in: text, from: start) else { return nil }
        let candidate = String(text[start...end])
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        guard let compact = try? JSONSerialization.data(withJSONObject: object, options: []),
              let string = String(data: compact, encoding: .utf8) else {
            return nil
        }
        return string
    }

    nonisolated private static func stripANSI(_ string: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;]*[A-Za-z]") else {
            return string
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return expression.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: "")
    }

    nonisolated private static func matchingBrace(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // Never echo authorization output: even malformed token JSON may contain secrets.
    nonisolated private static func sanitizedTail(_ output: String, limit: Int = 500) -> String {
        "Helper output was omitted to protect credentials."
    }

    nonisolated static func validRemoteName(_ name: String) -> Bool {
        !name.isEmpty && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && !name.hasPrefix("-") && !name.contains(":") && !name.contains("/")
            && !name.contains("\\") && !name.contains("[") && !name.contains("]")
            && validINIValue(name)
    }

    nonisolated private static func validINIValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
