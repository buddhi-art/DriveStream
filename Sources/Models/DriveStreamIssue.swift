import Foundation

/// A concise recovery message for the UI with bounded, safe diagnostics.
/// Private helper logs are used only for classification, never embedded in view state.
struct DriveStreamIssue: Equatable, Sendable, Identifiable {
    enum Recovery: String, Sendable {
        case retryMount
        case retryUnmount
        case openSetup
        case openSettings
    }

    let id: UUID
    let title: String
    let summary: String
    let details: String
    let recovery: Recovery

    init(title: String, summary: String, details: String = "", recovery: Recovery = .retryMount) {
        self.id = UUID()
        self.title = title
        self.summary = summary
        self.details = DiagnosticRedactor.redact(details)
        self.recovery = recovery
    }

    static let privateLogNotice = "Helper output and paths are kept out of this message. Choose Open Logs to inspect the private rclone log."

    static func mountFailure(description: String, log: String = "") -> DriveStreamIssue {
        // These inputs may contain filenames, URLs or credential-bearing text.
        // Translate known causes into fixed copy; never put the inputs in the UI.
        let lower = [description, log].joined(separator: "\n").lowercased()
        if lower.contains("encrypted remote is not configured") || lower.contains("encryption password is missing") {
            return DriveStreamIssue(
                title: "Encryption setup needs attention",
                summary: "Open the Setup Assistant to finish encryption setup. Keep the existing password for previously encrypted files.",
                details: privateLogNotice, recovery: .openSetup
            )
        }
        if lower.contains("invalid_grant") || lower.contains("token has expired")
            || lower.contains("token has been expired") || lower.contains("oauth token")
            || lower.contains("google drive remote is missing") || lower.contains("not connected") {
            return DriveStreamIssue(
                title: "Google Drive needs to reconnect",
                summary: "Open the Setup Assistant and sign in again. Files in Google Drive are unchanged.",
                details: privateLogNotice, recovery: .openSetup
            )
        }
        if lower.contains("not empty") || lower.contains("symbolic link")
            || lower.contains("mount point must") || lower.contains("another volume is still mounted") {
            return DriveStreamIssue(
                title: "The mount folder is unavailable",
                summary: "Choose an empty folder in Settings, or close apps using this volume and unmount it before trying again.",
                details: privateLogNotice, recovery: .openSettings
            )
        }
        if lower.contains("unknown flag") || lower.contains("rclone is not available")
            || lower.contains("rclone is not installed") || lower.contains("binary failed verification") {
            return DriveStreamIssue(
                title: "rclone needs attention",
                summary: "Download or update the official rclone helper in Settings, then try mounting again.",
                details: privateLogNotice, recovery: .openSettings
            )
        }
        if lower.contains("429") || lower.contains("ratelimitexceeded")
            || lower.contains("rate limit") || lower.contains("quota exceeded") {
            return DriveStreamIssue(
                title: "Google Drive is limiting requests",
                summary: "Wait a moment and try again. A personal OAuth client reduces shared-client quota pressure, but Google can still apply account limits.",
                details: privateLogNotice
            )
        }
        if lower.contains("network is unreachable") || lower.contains("no such host")
            || lower.contains("timed out") || lower.contains("deadline exceeded")
            || lower.contains("connection refused") || lower.contains("connection reset") {
            return DriveStreamIssue(
                title: "The drive could not connect",
                summary: "Check your internet connection, then retry. Cached data and files in Google Drive have not been deleted.",
                details: privateLogNotice
            )
        }
        if lower.contains("no compatible filesystem") || lower.contains("no fuse")
            || lower.contains("macfuse") || lower.contains("fuse-t") || lower.contains("fskit") {
            return DriveStreamIssue(
                title: "The filesystem driver is not ready",
                summary: "Check the driver approval in System Settings, or choose the built-in NFS backend in DriveStream Settings.",
                details: privateLogNotice, recovery: .openSettings
            )
        }
        return DriveStreamIssue(
            title: "The volume could not be mounted",
            summary: "Try mounting again. If it fails, check the filesystem backend in Settings or open the private rclone log.",
            details: privateLogNotice
        )
    }
}

enum DiagnosticRedactor {
    /// Treat logs as sensitive: rclone may include OAuth responses and credentials
    /// in a startup failure. Keep a useful tail without exposing token/password text.
    static func redact(_ text: String, limit: Int = 12_000) -> String {
        var result = text
        let patterns: [String] = [
            #"(?i)("(?:access_token|refresh_token|id_token|client_secret|password|password2)"\s*:\s*")(?:\\.|[^"\\])*(")"#,
            #"(?im)(\b(?:token|access_token|refresh_token|client_secret|password|password2)\s*=\s*)[^\r\n]+"#,
            #"(?i)(--(?:rc-pass|pass|password|client-secret)(?:\s+|=))(?:"(?:\\.|[^"\\])*"|'[^']*'|[^\s]+)"#,
            #"(?i)(Authorization:\s*(?:Basic|Bearer)\s+)[^\s]+"#,
            #"(?i)(https?://)[^\s/@:]+:[^\s/@]+@"#
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let replacement = index == 0 ? "$1[redacted]$2" : "$1[redacted]"
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        // Authorization URLs can contain OAuth state, authorization codes and tokens.
        if let expression = try? NSRegularExpression(pattern: #"(?i)([?&](?:code|state|access_token|refresh_token|client_secret)=)[^&\s]+"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: "$1[redacted]")
        }
        return String(result.suffix(max(0, limit))).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
