import Foundation

/// rclone's read-only `backend drives` response. IDs, not display names, select a root.
struct GoogleSharedDrive: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func decodeList(_ output: String) throws -> [GoogleSharedDrive] {
        guard output.utf8.count <= 1_048_576,
              let values = try? JSONDecoder().decode([GoogleSharedDrive].self, from: Data(output.utf8)),
              values.count <= 4_096 else { throw DriveRootError.invalidList }
        var seen = Set<String>()
        var drives: [GoogleSharedDrive] = []
        for drive in values {
            guard validID(drive.id), drive.name.utf8.count <= 4_096 else { throw DriveRootError.invalidList }
            let name = drive.name.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
                .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            guard seen.insert(drive.id).inserted else { continue }
            let label = String(String.UnicodeScalarView(name))
            drives.append(GoogleSharedDrive(id: drive.id, name: label.isEmpty ? "Unnamed Shared Drive" : label))
        }
        return drives
    }
}

enum DriveRootError: LocalizedError {
    case invalidID, invalidList, notConnected, listingFailed, verificationFailed, configurationChanged, privateConfigUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidID:
            return "Enter a Shared Drive ID using only letters, numbers, hyphens and underscores, or select My Drive."
        case .invalidList:
            return "The Shared Drive list could not be read. Refresh it, or enter a Shared Drive ID."
        case .notConnected:
            return "Connect Google Drive in the Setup Assistant before choosing a mount root."
        case .listingFailed:
            return "Shared Drives could not be loaded. Check your connection and account access, then refresh or enter an ID."
        case .verificationFailed:
            return "The selected drive could not be opened. Check the ID, your connection and your account's access. The previous mount root was kept."
        case .configurationChanged:
            return "The Google Drive configuration changed during this operation. Reopen Settings and try again."
        case .privateConfigUnavailable:
            return "The private Google Drive configuration could not be read or saved. Open Logs or reconnect in the Setup Assistant."
        }
    }
}
