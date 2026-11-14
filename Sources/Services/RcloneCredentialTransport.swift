import Foundation

/// Testable boundary: regression tests use an in-memory store and never touch a
/// user's Keychain. Existing public service initialization still takes KeychainHelper.
@MainActor
protocol RcloneCredentialStore {
    func save(_ secret: String, for account: String) throws
    func readString(for account: String) throws -> String?
    func delete(for account: String) throws
}

extension KeychainHelper: RcloneCredentialStore {}

/// The official authorize command accepts a backend, NOT a named remote. Its
/// ConfigMap reads supported backend environment options for that temporary remote:
/// https://github.com/rclone/rclone/blob/v1.75.2/fs/config/authorize.go
/// https://github.com/rclone/rclone/blob/v1.75.2/fs/configmap.go
/// Only these deliberate options cross the launch boundary, never positional
/// secrets or inherited RCLONE_* options. Same-user debuggers can still read a
/// helper's environment (and children may inherit it); this is not a vault.
enum RcloneOAuthAuthorization {
    static func run(executable: String, clientID: String, clientSecret: String) async throws -> CommandResult {
        let directory = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-oauth-")
        defer { ServiceFileSafety.removeTemporaryDirectory(directory, prefix: "DriveStream-oauth-") }
        let config = directory.appendingPathComponent("rclone.conf")
        // Isolate any **temp-fs** changes from the user's persistent config.
        try ServiceFileSafety.createPrivateFile(config)
        var environment: [String: String] = [:]
        if !clientID.isEmpty {
            environment["RCLONE_DRIVE_CLIENT_ID"] = clientID
            environment["RCLONE_DRIVE_CLIENT_SECRET"] = clientSecret
        }
        return try await CommandRunner.run(executable: executable,
            arguments: ["--config", config.path, "authorize", "drive"],
            timeout: 300, environment: environment)
    }
}

/// Snapshot first; partial credential writes must be recoverable. Restoration
/// attempts every account even if one fails, without surfacing secret values.
@MainActor
struct RcloneCredentialSnapshot {
    private let values: [(account: String, value: String?)]

    init(accounts: [String], store: any RcloneCredentialStore) throws {
        values = try accounts.map { ($0, try store.readString(for: $0)) }
    }

    func restore(to store: any RcloneCredentialStore) throws {
        var failed = false
        for (account, value) in values {
            do {
                if let value { try store.save(value, for: account) }
                else { try store.delete(for: account) }
            } catch { failed = true }
        }
        if failed {
            throw RcloneConfigError.keychain("The previous credentials could not be fully restored. Keep your encryption recovery keys safe before retrying.")
        }
    }
}
