import Foundation

/// Resolves the two onboarding modes without carrying a stale personal client into
/// default mode or silently reusing the secret belonging to a different client ID.
struct GoogleOAuthCredentials: Sendable, Equatable {
    let clientID: String
    let clientSecret: String

    static func resolve(
        useCustomClient: Bool,
        clientID: String,
        enteredSecret: String,
        storedClientID: String,
        storedSecret: String?
    ) throws -> GoogleOAuthCredentials {
        guard useCustomClient else {
            return GoogleOAuthCredentials(clientID: "", clientSecret: "")
        }
        let identifier = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let entered = enteredSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw RcloneConfigError.invalidClientCredentials("Enter a Google Cloud Client ID, or choose rclone default credentials.")
        }
        let matchingStoredSecret = identifier == storedClientID
            ? (storedSecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let secret = entered.isEmpty ? matchingStoredSecret : entered
        guard !secret.isEmpty else {
            throw RcloneConfigError.invalidClientCredentials("Enter the Client Secret for this Client ID, or choose rclone default credentials.")
        }
        return GoogleOAuthCredentials(clientID: identifier, clientSecret: secret)
    }
}
