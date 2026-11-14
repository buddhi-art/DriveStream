import Foundation

/// Discovers the port that rclone actually bound, rather than probing a port and
/// releasing it before launch (which creates a time-of-check/time-of-use race).
/// rclone owns the listener from the moment the kernel chooses the port.
enum RCServerEndpoint {
    static let listenAddress = "127.0.0.1:0"
    private static let announcement = "Serving remote control on "

    /// Accept only the exact loopback address we asked rclone to bind. A remote
    /// filename, credential-bearing URL, or other log line must never redirect RC.
    static func parseAnnouncement(_ log: String) -> URL? {
        for rawLine in log.split(separator: "\n") {
            guard let marker = rawLine.range(of: announcement) else { continue }
            let prefix = String(rawLine[..<marker.lowerBound])
            // Accept the log header, not an INFO filename containing fake NOTICE
            // text. rclone --log-format date,time uses this exact numeric prefix.
            guard prefix.range(
                of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} NOTICE\s*: $"#,
                options: .regularExpression
            ) != nil else { continue }
            let value = rawLine[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value), isAllowed(url) else { continue }
            return url
        }
        return nil
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http",
              components.host == "127.0.0.1",
              let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return false }
        return true
    }

    /// The announcement is in the beginning of the per-process log. Reading a
    /// bounded prefix avoids loading a multi-hour log or missing the announcement
    /// when a very large mount is already generating log traffic.
    static func readAnnouncement(from logURL: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        return parseAnnouncement(String(decoding: data, as: UTF8.self))
    }
}
