import Foundation
import os

/// Classification is deliberately separate from retry policy. In particular,
/// refresh and forget are side effects and this client never retries them.
enum RcloneRCError: LocalizedError, Sendable {
    case configuration(String)
    case transport(code: URLError.Code, message: String)
    case invalidResponse
    case http(status: Int, message: String)
    case decoding(path: String, message: String)
    case encoding(String)
    case staleSession

    var isTransient: Bool {
        switch self {
        case .transport(let code, _):
            switch code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
                 .cannotLoadFromNetwork, .backgroundSessionWasDisconnected:
                return true
            default:
                return false
            }
        case .http(let status, _):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .configuration, .invalidResponse, .decoding, .encoding, .staleSession:
            return false
        }
    }

    var statusCode: Int? {
        if case .http(let status, _) = self { return status }
        return nil
    }

    var transportCode: URLError.Code? {
        if case .transport(let code, _) = self { return code }
        return nil
    }

    var isAuthenticationFailure: Bool { statusCode == 401 || statusCode == 403 }

    var errorDescription: String? {
        switch self {
        case .configuration(let message):
            return "The rclone control connection is not configured: \(message)"
        case .transport(_, let message):
            return "The rclone control server is not reachable: \(message)"
        case .invalidResponse:
            return "The rclone control server returned a non-HTTP response."
        case .http(let status, let message):
            if isAuthenticationFailure {
                return "The rclone control server rejected DriveStream's credentials."
            }
            return "rclone RC request failed (\(status)): \(message)"
        case .decoding(let path, let message):
            return "Could not read the rclone response for \(path): \(message)"
        case .encoding(let message):
            return "Could not encode the rclone request: \(message)"
        case .staleSession:
            return "The rclone control connection changed while the request was running."
        }
    }
}

/// An authenticated connection to a single, explicitly discovered mount process.
/// No request is sent until both a literal-loopback endpoint and credentials exist.
final class RcloneRCClient: Sendable {
    static let defaultUsername = "drivestream"

    private struct ConnectionState: Sendable {
        var baseURL: URL?
        var authorizationHeader: String?
        var generation = UUID()
    }

    private struct ConnectionSnapshot: Sendable {
        let baseURL: URL
        let authorizationHeader: String
        let generation: UUID
    }

    private let connection: OSAllocatedUnfairLock<ConnectionState>
    private let session: URLSession

    /// A snapshot, not a mutable public endpoint. Authentication and endpoint
    /// always come from the same locked state when constructing a request.
    var baseURL: URL? { connection.withLock { $0.baseURL } }

    init(baseURL: URL? = nil, timeout: TimeInterval = 5) {
        // This convenience initializer cannot throw; invalid URLs fail closed.
        let validatedURL = baseURL.flatMap { try? Self.validateEndpoint($0) }
        connection = OSAllocatedUnfairLock(initialState: ConnectionState(baseURL: validatedURL))
        let sessionTimeout = timeout.isFinite && timeout > 0 ? timeout : 5
        let configuration = URLSessionConfiguration.ephemeral
        // Preserve endpoint-specific deadlines; these are only session defaults.
        configuration.timeoutIntervalForRequest = max(sessionTimeout, 30)
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: RcloneRCSessionDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: Connection lifecycle

    /// Validates before taking the lock, then publishes endpoint and auth as one
    /// new generation. Invalid input throws without altering the prior connection.
    func configure(baseURL: URL, username: String, password: String) throws {
        let endpoint = try Self.validateEndpoint(baseURL)
        let authorization = try Self.makeAuthorization(username: username, password: password)
        connection.withLock {
            $0 = ConnectionState(baseURL: endpoint, authorizationHeader: authorization)
        }
    }

    /// Convenience for callers that supplied an explicit URL at initialization.
    /// Empty/invalid credentials fail closed. This cannot restore a cleared URL;
    /// a new mount must use configure(baseURL:username:password:).
    func setCredentials(username: String, password: String) {
        guard let authorization = try? Self.makeAuthorization(username: username, password: password) else {
            clearCredentials()
            return
        }
        connection.withLock {
            $0.authorizationHeader = authorization
            $0.generation = UUID()
        }
    }

    /// Invalidates both the credentials and the discovered process endpoint.
    func clearCredentials() {
        connection.withLock { $0 = ConnectionState(baseURL: nil) }
    }

    // MARK: Health and identity

    /// Reachability is diagnostic only: an HTTP auth error still means a server
    /// answered. Use processID() to verify the authenticated mount process.
    func isReachable() async -> Bool {
        do {
            _ = try await postData(path: "rc/noop", body: EmptyRequest(), timeout: 1.2)
            return true
        } catch let error as RcloneRCError {
            if case .http = error { return true }
            return false
        } catch {
            return false
        }
    }

    func ping() async -> Bool {
        do {
            try await authenticate()
            return true
        } catch {
            return false
        }
    }

    /// Unlike ping(), preserves cancellation and the typed error for callers.
    func authenticate() async throws {
        _ = try await postData(path: "rc/noop", body: EmptyRequest(), timeout: 1.5)
    }

    /// Authenticated identity from core/pid, for comparison with Process.processIdentifier.
    func processID() async throws -> Int {
        let response: PIDResponse = try await post(path: "core/pid", body: EmptyRequest(), timeout: 1.5)
        guard response.pid > 0 else {
            throw RcloneRCError.decoding(path: "core/pid", message: "The process ID was not positive.")
        }
        return response.pid
    }

    // MARK: Directory pre-warming

    /// Exact asynchronous rclone shape: {"recursive":"true","_async":true}.
    /// Not retried: a lost response may already have started the refresh job.
    func refresh() async throws -> RcloneAsyncJob {
        try await post(path: "vfs/refresh", body: RefreshRequest(), timeout: 20)
    }

    func jobStatus(jobID: Int) async throws -> RcloneJobStatus {
        try await post(path: "job/status", body: JobStatusRequest(jobid: jobID), timeout: 8)
    }

    // MARK: Quota and statistics

    func about(remote: String) async throws -> RcloneAbout {
        try await post(path: "operations/about", body: AboutRequest(fs: Self.normalizeRemote(remote)), timeout: 20)
    }

    func coreStats() async throws -> RcloneCoreStats {
        try await post(path: "core/stats", body: EmptyRequest(), timeout: 6)
    }

    /// Omitting fs targets the single active VFS, not an ambiguous cache key.
    func vfsStats(remote _: String) async throws -> RcloneVFSStats {
        try await post(path: "vfs/stats", body: EmptyRequest(), timeout: 6)
    }

    /// Fresh queue evidence for write status and exit decisions. Never pass fs:
    /// DriveStream owns exactly one VFS in this helper process.
    func uploadQueue() async throws -> RcloneUploadQueue {
        try await post(path: "vfs/queue", body: EmptyRequest(), timeout: 6)
    }

    /// Idempotent runtime bandwidth setting: upload:download in rclone units.
    func setBandwidthLimit(_ rate: String) async throws {
        _ = try await postData(path: "core/bwlimit", body: BandwidthRequest(rate: rate), timeout: 6)
    }

    // MARK: Cache invalidation (never automatically retried)

    func forgetAll(remote _: String) async throws -> RcloneForgetResponse {
        try await post(path: "vfs/forget", body: EmptyRequest(), timeout: 12)
    }

    func forget(relativePath: String, isDirectory: Bool, remote: String) async throws -> RcloneForgetResponse {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return try await forgetAll(remote: remote) }
        let body = ForgetRequest(file: isDirectory ? nil : trimmed, dir: isDirectory ? trimmed : nil)
        return try await post(path: "vfs/forget", body: body, timeout: 12)
    }

    // MARK: Transport

    private static func normalizeRemote(_ remote: String) -> String {
        remote.hasSuffix(":") ? remote : "\(remote):"
    }

    /// Accept literal IPv4 loopback (127/8) or IPv6 ::1 only. Hostnames, including
    /// localhost, are intentionally rejected to avoid DNS/hosts-file surprises.
    /// RC endpoints have an explicit nonzero port and no URL credentials or suffix.
    private static func validateEndpoint(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http" || components.scheme == "https",
              let host = components.host,
              let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw RcloneRCError.configuration("Expected an explicit loopback HTTP endpoint without URL credentials, path, query, or fragment.")
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4Loopback = octets.count == 4 && octets.first == "127" && octets.allSatisfy {
            guard let value = UInt8($0) else { return false }
            return String(value) == $0
        }
        guard isIPv4Loopback || host == "::1" || host == "[::1]" else {
            throw RcloneRCError.configuration("The RC endpoint must use a literal loopback address.")
        }
        components.path = ""
        guard let endpoint = components.url else {
            throw RcloneRCError.configuration("The RC endpoint is invalid.")
        }
        return endpoint
    }

    private static func makeAuthorization(username: String, password: String) throws -> String {
        guard !username.isEmpty, !password.isEmpty, !username.contains(":"),
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RcloneRCError.configuration("Nonempty valid RC username and password are required.")
        }
        return "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
    }

    private func snapshot() throws -> ConnectionSnapshot {
        try Task.checkCancellation()
        return try connection.withLock {
            guard let baseURL = $0.baseURL, let authorizationHeader = $0.authorizationHeader else {
                throw RcloneRCError.configuration("No active authenticated mount endpoint.")
            }
            return ConnectionSnapshot(baseURL: baseURL, authorizationHeader: authorizationHeader, generation: $0.generation)
        }
    }

    private func checkGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard connection.withLock({ $0.generation == generation }) else {
            throw RcloneRCError.staleSession
        }
    }

    private func postData<Body: Encodable & Sendable>(
        path: String, body: Body, timeout: TimeInterval
    ) async throws -> (data: Data, generation: UUID) {
        let snapshot = try snapshot()
        var url = snapshot.baseURL
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(snapshot.authorizationHeader, forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw RcloneRCError.encoding(error.localizedDescription)
        }
        try checkGeneration(snapshot.generation)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // URLSession reports cancelled tasks as URLError.cancelled. Do not
            // erase cancellation into an ordinary telemetry/transport failure.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            try checkGeneration(snapshot.generation)
            throw RcloneRCError.transport(code: (error as? URLError)?.code ?? .unknown, message: error.localizedDescription)
        }
        try checkGeneration(snapshot.generation)
        guard let http = response as? HTTPURLResponse else { throw RcloneRCError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(RcloneErrorPayload.self, from: data)
            let fallback = String(decoding: data.prefix(800), as: UTF8.self)
            let message = payload?.error?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (fallback.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode) : fallback)
            try checkGeneration(snapshot.generation)
            throw RcloneRCError.http(status: http.statusCode, message: message)
        }
        return (data, snapshot.generation)
    }

    private func post<T: Decodable & Sendable, Body: Encodable & Sendable>(
        path: String, body: Body, timeout: TimeInterval
    ) async throws -> T {
        let response = try await postData(path: path, body: body, timeout: timeout)
        guard !response.data.isEmpty else {
            try checkGeneration(response.generation)
            throw RcloneRCError.decoding(path: path, message: "The response body was empty.")
        }
        let value: T
        do {
            value = try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            try checkGeneration(response.generation)
            throw RcloneRCError.decoding(path: path, message: error.localizedDescription)
        }
        try checkGeneration(response.generation)
        return value
    }
}

// Typed Sendable JSON bodies avoid heterogeneous dictionaries at suspension points.
private struct EmptyRequest: Encodable, Sendable {}
private struct RefreshRequest: Encodable, Sendable {
    let recursive = "true"
    let _async = true
}
private struct JobStatusRequest: Encodable, Sendable { let jobid: Int }
private struct AboutRequest: Encodable, Sendable { let fs: String }
private struct ForgetRequest: Encodable, Sendable {
    let file: String?
    let dir: String?
}
private struct PIDResponse: Decodable, Sendable { let pid: Int }
private struct BandwidthRequest: Encodable, Sendable { let rate: String }

/// Reject every redirect, even same-host ones: RC has no redirecting endpoints,
/// and credentials must never leave the explicitly configured origin. The client
/// receives the original 3xx response and classifies it as a permanent HTTP error.
private final class RcloneRCSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
