import Foundation

/// Targeted INI edit for the app-owned, unencrypted rclone config. Unrelated
/// sections, comments, unknown options and option whitespace are kept byte-for-byte.
/// Crypt values arrive already obscured and contain no INI metacharacters.
enum RclonePrivateConfig {
    static func updating(_ data: Data, section: String, options: [String: String?]) throws -> Data {
        guard let contents = String(data: data, encoding: .utf8),
              RcloneConfigService.validRemoteName(section) else {
            throw RcloneConfigError.invalidConfiguration("The private config is not a supported unencrypted UTF-8 INI file.")
        }
        var lines = contents.components(separatedBy: "\n")
        // Official encrypted configs begin with comments/blank lines followed by
        // RCLONE_ENCRYPT_V0:. Match rclone's first significant line, not byte zero.
        let firstSignificantLine = lines.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix(";") }
        guard firstSignificantLine?.hasPrefix("RCLONE_ENCRYPT_V") != true else {
            throw RcloneConfigError.invalidConfiguration("Encrypted rclone configuration files cannot be edited by DriveStream.")
        }
        for (key, value) in options {
            guard !key.isEmpty, !key.contains("="), !key.contains("["), !key.contains("]"),
                  !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !(value ?? "").unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw RcloneConfigError.invalidConfiguration("Invalid rclone config key or value.")
            }
        }
        let headers: [(index: Int, name: String)] = lines.enumerated().compactMap { index, raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
            return (index, String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let matches = headers.filter { $0.name == section }
        guard matches.count <= 1 else {
            throw RcloneConfigError.invalidConfiguration("The config contains a duplicate target section.")
        }
        if let header = matches.first {
            let end = headers.first(where: { $0.index > header.index })?.index ?? lines.count
            var seen = Set<String>()
            var updated: [String] = []
            for raw in lines[(header.index + 1)..<end] {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.hasPrefix("#"), !line.hasPrefix(";"), let equals = line.firstIndex(of: "=") {
                    let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let value = options[key] {
                        if seen.insert(key).inserted, let value { updated.append("\(key) = \(value)") }
                        continue // Remove duplicates and explicit nil values.
                    }
                }
                updated.append(raw)
            }
            let additions = options.keys.sorted().filter { !seen.contains($0) }.compactMap { key -> String? in
                guard let wrapped = options[key], let value = wrapped else { return nil }
                return "\(key) = \(value)"
            }
            // Insert before trailing blank lines, keeping the next section separated.
            let insertion = updated.lastIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).map { $0 + 1 } ?? 0
            updated.insert(contentsOf: additions, at: insertion)
            lines.replaceSubrange((header.index + 1)..<end, with: updated)
        } else {
            if lines.last != "" { lines.append("") }
            lines += ["[\(section)]"]
            lines += options.keys.sorted().compactMap { key -> String? in
                guard let wrapped = options[key], let value = wrapped else { return nil }
                return "\(key) = \(value)"
            }
            lines.append("")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}
