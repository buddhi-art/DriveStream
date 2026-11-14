import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case dataCorrupted
    case emptyAccount

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            return "Keychain error \(status): \(message)"
        case .dataCorrupted:
            return "The saved Keychain secret could not be decoded."
        case .emptyAccount:
            return "The Keychain account name must not be empty."
        }
    }
}

enum KeychainAccountName {
    static let cryptPassword = "crypt.password"
    static let cryptSaltPassword = "crypt.salt-password"
    static let googleClientSecret = "google.oauth.client-secret"
}

/// Typed, immutable query identity. Preserve the existing file-based Keychain
/// search/default-keychain behavior: changing stores would hide existing secrets.
struct KeychainItemQuery: Hashable, Sendable {
    let service: String
    let account: String

    var attributes: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    func matching(_ result: KeychainMatchResult) -> [CFString: Any] {
        var query = attributes
        query[kSecMatchLimit] = kSecMatchLimitOne
        switch result {
        case .secret:
            query[kSecReturnData] = true
        case .presence:
            // A status-only metadata query, never a password read. Skip any item
            // needing authentication instead of retrying interactively. Unlike
            // UIAllow/UIFail, UISkip is not deprecated on macOS 14.
            query[kSecReturnData] = false
            query[kSecUseAuthenticationUI] = kSecUseAuthenticationUISkip
        }
        return query
    }
}

enum KeychainMatchResult: Equatable, Sendable {
    case secret, presence
}

struct KeychainCopyResult: Sendable {
    let status: OSStatus
    let data: Data?
}

/// SecItem is synchronous; typed values keep Any/CF objects confined to the
/// system adapter. Tests inject a checked-Sendable in-memory implementation.
protocol KeychainSecItemOperations: Sendable {
    func update(_ query: KeychainItemQuery, data: Data) -> OSStatus
    func add(_ query: KeychainItemQuery, data: Data) -> OSStatus
    func copyMatching(_ query: KeychainItemQuery, returning: KeychainMatchResult) -> KeychainCopyResult
    func delete(_ query: KeychainItemQuery) -> OSStatus
}

private struct SystemKeychainSecItemOperations: KeychainSecItemOperations {
    func update(_ query: KeychainItemQuery, data: Data) -> OSStatus {
        SecItemUpdate(query.attributes as CFDictionary, [kSecValueData: data] as CFDictionary)
    }

    func add(_ query: KeychainItemQuery, data: Data) -> OSStatus {
        var attributes = query.attributes
        attributes[kSecValueData] = data
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func copyMatching(_ query: KeychainItemQuery, returning: KeychainMatchResult) -> KeychainCopyResult {
        let attributes = query.matching(returning) as CFDictionary
        if returning == .presence {
            return KeychainCopyResult(status: SecItemCopyMatching(attributes, nil), data: nil)
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes, &result)
        return KeychainCopyResult(status: status, data: result as? Data)
    }

    func delete(_ query: KeychainItemQuery) -> OSStatus {
        SecItemDelete(query.attributes as CFDictionary)
    }
}

/// Wrapper around the macOS file-based (normally login) Keychain. Its ACLs and
/// lock state govern secret access; a standard item is NOT freely readable by
/// every same-user process. See Apple's TN3137: On Mac keychain APIs and implementations.
///
/// No silent migration or biometric policy is applied here. User-presence
/// protection needs explicit opt-in, data-protection Keychain routing, and a
/// failure-safe migration. Adding kSecAttrAccessible to a legacy item alone does
/// not provide that protection. Crypt passwords also remain recoverable from
/// reversibly obscured copies in rclone.conf (mode 0600). OAuth tokens also live in
/// that private config; Keychain access controls do not protect those file copies.
final class KeychainHelper: Sendable {
    static let shared = KeychainHelper()

    private let service: String
    private let operations: any KeychainSecItemOperations

    init(service: String = "com.drivestream.app", operations: any KeychainSecItemOperations = SystemKeychainSecItemOperations()) {
        self.service = service
        self.operations = operations
    }

    func save(_ secret: String, for account: String) throws {
        let query = try item(for: account)
        if secret.isEmpty {
            try delete(for: account)
            return
        }
        let data = Data(secret.utf8)
        let updateStatus = operations.update(query, data: data)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = operations.add(query, data: data)
            if addStatus == errSecDuplicateItem {
                // Another writer inserted between update and add. Retry only this
                // exact item, never delete/recreate it or weaken access controls.
                let retryStatus = operations.update(query, data: data)
                guard retryStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(retryStatus) }
                return
            }
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            // Cancellation, refusal, and locked-Keychain failures are not absence.
            // Surface the original status without a fallback or destructive retry.
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Preserves the existing login-Keychain authentication behavior. Callers must
    /// not use this to determine whether an item exists; use containsValue instead.
    func readString(for account: String) throws -> String? {
        let result = operations.copyMatching(try item(for: account), returning: .secret)
        switch result.status {
        case errSecSuccess:
            guard let data = result.data, let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataCorrupted
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(result.status)
        }
    }

    func delete(for account: String) throws {
        let status = operations.delete(try item(for: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// A best-effort metadata probe, not proof that a secret is readable. False
    /// also includes access/lock errors or skipped items; never retry with data/UI.
    func containsValue(for account: String) -> Bool {
        guard let query = try? item(for: account) else { return false }
        return operations.copyMatching(query, returning: .presence).status == errSecSuccess
    }

    private func item(for account: String) throws -> KeychainItemQuery {
        guard !account.isEmpty else { throw KeychainError.emptyAccount }
        return KeychainItemQuery(service: service, account: account)
    }
}
