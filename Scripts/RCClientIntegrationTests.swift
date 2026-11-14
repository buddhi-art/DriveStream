// Standalone Swift 6 integration checks. Only explicitly supplied mock URLs
// are used; this harness never invokes rclone or accesses user configuration.
import Foundation

private struct TestFailure: Error, Sendable, CustomStringConvertible {
    let description: String
}

private struct MockFixture: Decodable, Sendable {
    let primaryURL: URL
    let secondaryURL: URL
    let pid: Int
}

private struct MockBehavior: Encodable, Sendable {
    var status: Int?
    var delay: Double?
    var raw: String?
    var close: Bool?
    var redirect: String?
}

private struct MockControlRequest: Encodable, Sendable {
    let endpoint: String
    let behaviors: [MockBehavior]
}

private struct MockState: Decodable, Sendable {
    let counts: [String: Int]
    let unauthorized: Int
    let redirectHits: Int
    let redirectAuthorizations: [String]

    func count(_ endpoint: String) -> Int { counts[endpoint, default: 0] }
}

/// Test-only control plane. Every URL is relative to a dynamic mock fixture.
private final class MockControl: Sendable {
    let baseURL: URL
    private let authorization: String
    private let session: URLSession

    init(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        authorization = "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
        session = URLSession(configuration: .ephemeral)
    }

    deinit { session.invalidateAndCancel() }

    func set(_ endpoint: String, _ behaviors: [MockBehavior]) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("_test/control"))
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(MockControlRequest(endpoint: endpoint, behaviors: behaviors))
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TestFailure(description: "Mock control request failed")
        }
    }

    func state() async throws -> MockState {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("_test/state"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TestFailure(description: "Mock state request failed")
        }
        return try JSONDecoder().decode(MockState.self, from: data)
    }

    func waitForRequest(_ endpoint: String, after count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if try await state().count(endpoint) > count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestFailure(description: "Timed out waiting for mock to receive \(endpoint)")
    }

    func options() async throws -> Int {
        struct Options: Decodable, Sendable {
            struct VFS: Decodable, Sendable { let CacheMode: Int }
            let vfs: VFS
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("options/get"))
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TestFailure(description: "Mock options request failed")
        }
        return try JSONDecoder().decode(Options.self, from: data).vfs.CacheMode
    }
}

@main
struct RCClientIntegrationTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(description: message) }
        print("ok - \(message)")
    }

    private static func expectRCError<T: Sendable>(
        _ message: String, matching: @Sendable (RcloneRCError) -> Bool,
        operation: @Sendable () async throws -> T
    ) async throws {
        do {
            _ = try await operation()
            throw TestFailure(description: "\(message): unexpectedly succeeded")
        } catch let error as RcloneRCError {
            try expect(matching(error), "\(message) [\(error)]")
        }
    }

    private static func configure(_ client: RcloneRCClient, _ fixture: MockFixture, secondary: Bool = false) throws {
        try client.configure(baseURL: secondary ? fixture.secondaryURL : fixture.primaryURL,
                             username: secondary ? "second" : "drivestream",
                             password: secondary ? "new-secret" : "secret")
    }

    private static func lifecycleTests(_ fixture: MockFixture, _ control: MockControl) async throws {
        let client = RcloneRCClient()
        let before = try await control.state().count("/rc/noop")
        try expect(client.baseURL == nil, "production initializer has no fixed-port endpoint")
        let unconfiguredPing = await client.ping()
        try expect(!unconfiguredPing, "unconfigured ping fails closed")
        try await expectRCError("unconfigured calls fail closed", matching: { !$0.isTransient && $0.statusCode == nil }) {
            try await client.coreStats()
        }
        let after = try await control.state().count("/rc/noop")
        try expect(after == before, "unconfigured client sends no HTTP request")

        let endpointOnly = RcloneRCClient(baseURL: fixture.primaryURL)
        try await expectRCError("explicit endpoint without credentials fails closed", matching: {
            if case .configuration = $0 { return !$0.isTransient }; return false
        }) { try await endpointOnly.coreStats() }
        endpointOnly.setCredentials(username: "drivestream", password: "secret")
        try await endpointOnly.authenticate()
        try expect(endpointOnly.baseURL == fixture.primaryURL, "setCredentials supports an explicit initializer URL")
        endpointOnly.clearCredentials()
        endpointOnly.setCredentials(username: "drivestream", password: "secret")
        try expect(endpointOnly.baseURL == nil, "setCredentials cannot resurrect a cleared process endpoint")

        try configure(client, fixture)
        try expect(client.baseURL == fixture.primaryURL, "configure publishes the discovered endpoint")
        for invalid in [
            "http://example.com:1234", "http://192.168.1.2:1234", "http://localhost:1234",
            "http://127.0.0.1.evil.example:1234", "http://127.0.0.1:0", "http://127.0.0.1",
            "ftp://127.0.0.1:1234", "http://user:secret@127.0.0.1:1234",
            "http://127.0.0.1:1234/path", "http://127.0.0.1:1234?query", "http://127.0.0.1:1234#fragment"
        ] {
            guard let url = URL(string: invalid) else { throw TestFailure(description: "Invalid test URL") }
            do {
                try client.configure(baseURL: url, username: "drivestream", password: "secret")
                throw TestFailure(description: "Accepted unsafe endpoint \(invalid)")
            } catch let error as RcloneRCError {
                guard case .configuration = error, !error.isTransient else { throw error }
            }
            try expect(client.baseURL == fixture.primaryURL, "unsafe endpoint rejected atomically: \(invalid)")
            try expect(RcloneRCClient(baseURL: url).baseURL == nil, "invalid initializer endpoint fails closed: \(invalid)")
        }
        for credentials in [("", "secret"), ("drivestream", ""), ("user:name", "secret"), ("user\n", "secret")] {
            do {
                try client.configure(baseURL: fixture.secondaryURL, username: credentials.0, password: credentials.1)
                throw TestFailure(description: "Accepted invalid credentials")
            } catch let error as RcloneRCError {
                guard case .configuration = error else { throw error }
            }
            try expect(client.baseURL == fixture.primaryURL, "invalid credentials leave prior endpoint/auth intact")
        }
        try await client.authenticate()
        try expect(RcloneRCClient(baseURL: URL(string: "http://[::1]:1234")!).baseURL != nil, "literal IPv6 loopback is allowed")
        client.setCredentials(username: "", password: "")
        try expect(client.baseURL == nil, "invalid convenience credentials clear endpoint and auth")
        try configure(client, fixture)
        client.clearCredentials()
        try expect(client.baseURL == nil, "clearCredentials clears the endpoint as well as auth")
    }

    private static func endpointTests(_ fixture: MockFixture, _ control: MockControl) async throws {
        let client = RcloneRCClient(baseURL: fixture.primaryURL)
        client.setCredentials(username: "drivestream", password: "secret")
        let reachable = await client.isReachable()
        try expect(reachable, "RC client can reach the mock server")
        let ping = await client.ping()
        try expect(ping, "authenticated rc/noop ping succeeds")
        try await client.authenticate()
        let pid = try await client.processID()
        try expect(pid == fixture.pid, "core/pid verifies authenticated process identity")
        let mode = try await control.options()
        try expect(mode == 3, "options/get mock sanity reports full VFS cache mode")
        let job = try await client.refresh()
        try expect(job.jobid == 41 && job.executeId == "mock-execute-id", "exact asynchronous vfs/refresh JSON returns a typed job")
        let status = try await client.jobStatus(jobID: 41)
        try expect(status.finished && status.succeeded, "job/status decodes completion")
        let about = try await client.about(remote: "gdrive")
        try expect(about.total == 5_000_000_000_000, "operations/about normalizes and decodes quota")
        let core = try await client.coreStats()
        try expect(core.transferring.count == 1 && core.bytes == 101, "core/stats transfer decodes")
        let vfs = try await client.vfsStats(remote: "deliberately-ignored:")
        try expect(vfs.cacheBytesUsed == 2048 && vfs.activeStreams == 3, "vfs/stats omits fs and decodes cache/streams")
        let file = try await client.forget(relativePath: "/Movies/Clip.mov/", isDirectory: false, remote: "ignored:")
        try expect(file.forgotten == ["Movies/Clip.mov"], "vfs/forget file body is trimmed and omits fs")
        let directory = try await client.forget(relativePath: "Movies", isDirectory: true, remote: "ignored:")
        try expect(directory.forgotten == ["Movies"], "vfs/forget directory body omits fs")
        let all = try await client.forgetAll(remote: "ignored:")
        try expect(all.forgotten == [], "vfs/forget all sends an empty JSON object")
        let empty = try await client.forget(relativePath: "///", isDirectory: false, remote: "ignored:")
        try expect(empty.forgotten == [], "empty trimmed path uses forget-all")

        client.setCredentials(username: "wrong", password: "wrong")
        try await expectRCError("401 authentication failure is permanent", matching: {
            $0.statusCode == 401 && $0.isAuthenticationFailure && !$0.isTransient
        }) { try await client.coreStats() }
        let rejectedPing = await client.ping()
        let rejectedReachable = await client.isReachable()
        try expect(!rejectedPing && rejectedReachable, "auth rejection is diagnostic reachability, not readiness")
        try configure(client, fixture)
        try await control.set("/core/stats", [MockBehavior(status: 403)])
        try await expectRCError("403 authentication failure is permanent", matching: {
            $0.statusCode == 403 && $0.isAuthenticationFailure && !$0.isTransient
        }) { try await client.coreStats() }
    }

    private static func errorAndRetryTests(_ fixture: MockFixture, _ control: MockControl) async throws {
        let client = RcloneRCClient()
        try configure(client, fixture)
        let before = try await control.state().count("/core/stats")
        try await control.set("/core/stats", [MockBehavior(status: 408), MockBehavior(status: 429), MockBehavior(status: 503)])
        var observed: [Int] = []
        var sample: RcloneCoreStats?
        // Caller-owned, bounded, read-only telemetry retry. Client sends each
        // attempt once, and supplies classification rather than retrying itself.
        for attempt in 0..<4 {
            do {
                sample = try await client.coreStats()
                break
            } catch let error as RcloneRCError {
                guard error.isTransient, let status = error.statusCode, attempt < 3 else { throw error }
                observed.append(status)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try expect(observed == [408, 429, 503] && sample?.bytes == 101, "caller can bound retries for real 408/429/503 sequence")
        let after = try await control.state().count("/core/stats")
        try expect(after - before == 4, "telemetry client performs exactly one request per caller attempt")

        for endpoint in ["/vfs/refresh", "/vfs/forget"] {
            let before = try await control.state().count(endpoint)
            try await control.set(endpoint, [MockBehavior(status: 503)])
            if endpoint == "/vfs/refresh" {
                try await expectRCError("refresh surfaces transient failure without retry", matching: { $0.statusCode == 503 && $0.isTransient }) {
                    try await client.refresh()
                }
            } else {
                try await expectRCError("forget surfaces transient failure without retry", matching: { $0.statusCode == 503 && $0.isTransient }) {
                    try await client.forgetAll(remote: "ignored:")
                }
            }
            let after = try await control.state().count(endpoint)
            try expect(after - before == 1, "side effect \(endpoint) is not automatically retried")
        }
        try await control.set("/core/stats", [MockBehavior(status: 400)])
        try await expectRCError("400 request failure is permanent", matching: { $0.statusCode == 400 && !$0.isTransient }) {
            try await client.coreStats()
        }
        for raw in ["", "not JSON", "[]"] {
            try await control.set("/core/stats", [MockBehavior(raw: raw)])
            try await expectRCError("malformed response is a permanent decoding error", matching: {
                if case .decoding(let path, _) = $0 { return path == "core/stats" && !$0.isTransient }; return false
            }) { try await client.coreStats() }
        }
        try await control.set("/core/pid", [MockBehavior(raw: "{\"pid\":0}")])
        try await expectRCError("invalid process identity is rejected", matching: {
            if case .decoding = $0 { return !$0.isTransient }; return false
        }) { try await client.processID() }

        let timeoutClient = RcloneRCClient(baseURL: fixture.primaryURL)
        timeoutClient.setCredentials(username: "drivestream", password: "secret")
        try await control.set("/rc/noop", [MockBehavior(delay: 2)])
        try await expectRCError("real URLSession timeout preserves URLError code and is transient", matching: {
            $0.transportCode == .timedOut && $0.isTransient
        }) { try await timeoutClient.authenticate() }
        try expect(!RcloneRCError.transport(code: .cancelled, message: "cancelled").isTransient, "cancelled transport is never retriable")
        try expect(!RcloneRCError.transport(code: .serverCertificateUntrusted, message: "TLS").isTransient, "TLS/auth/config failures are never transient")
        try expect(RcloneRCError.transport(code: .networkConnectionLost, message: "lost").isTransient, "connection loss has typed transient classification")
    }

    private static func redirectTests(_ fixture: MockFixture, _ primary: MockControl, _ secondary: MockControl) async throws {
        let client = RcloneRCClient()
        try configure(client, fixture)
        let primaryBefore = try await primary.state().redirectHits
        let secondaryBefore = try await secondary.state().redirectHits
        for code in [301, 302, 303, 307, 308] {
            for target in [fixture.primaryURL, fixture.secondaryURL] {
                let sink = target.appendingPathComponent("_test/redirect-sink").absoluteString
                try await primary.set("/rc/noop", [MockBehavior(status: code, redirect: sink)])
                try await expectRCError("\(code) redirect to \(target.port!) is blocked", matching: {
                    $0.statusCode == code && !$0.isTransient
                }) { try await client.authenticate() }
            }
        }
        let a = try await primary.state()
        let b = try await secondary.state()
        try expect(a.redirectHits == primaryBefore && b.redirectHits == secondaryBefore, "no same-origin or cross-origin redirect destination was contacted")
        try expect(a.redirectAuthorizations.isEmpty && b.redirectAuthorizations.isEmpty, "Basic credentials never leak to redirect destinations")
    }

    private static func cancellationAndGenerationTests(_ fixture: MockFixture, _ control: MockControl) async throws {
        let client = RcloneRCClient()
        try configure(client, fixture)
        let before = try await control.state().count("/core/stats")
        try await control.set("/core/stats", [MockBehavior(delay: 1)])
        let request = Task { try await client.coreStats() }
        try await control.waitForRequest("/core/stats", after: before)
        let start = ContinuousClock.now
        request.cancel()
        do {
            _ = try await request.value
            throw TestFailure(description: "Cancelled task unexpectedly succeeded")
        } catch is CancellationError {
            try expect(start.duration(to: .now) < .milliseconds(700), "in-flight cancellation stays CancellationError and completes promptly")
        }
        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.coreStats()
        }
        do {
            _ = try await alreadyCancelled.value
            throw TestFailure(description: "Pre-cancelled task unexpectedly succeeded")
        } catch is CancellationError {
            print("ok - pre-cancelled request preserves cancellation")
        }

        for mutation in ["configure", "clear", "credentials"] {
            try configure(client, fixture)
            let before = try await control.state().count("/core/stats")
            try await control.set("/core/stats", [MockBehavior(delay: 0.35)])
            let old = Task { try await client.coreStats() }
            try await control.waitForRequest("/core/stats", after: before)
            switch mutation {
            case "configure": try configure(client, fixture, secondary: true)
            case "clear": client.clearCredentials()
            default: client.setCredentials(username: "drivestream", password: "secret")
            }
            try await expectRCError("\(mutation) invalidates the in-flight response generation", matching: {
                if case .staleSession = $0 { return !$0.isTransient }; return false
            }) { try await old.value }
        }
        try configure(client, fixture, secondary: true)
        let new = try await client.coreStats()
        try expect(new.bytes == 202, "new mount receives only its newly configured server's stats")
    }

    private static func concurrencyTests(_ fixture: MockFixture, _ primary: MockControl, _ secondary: MockControl) async throws {
        let client = RcloneRCClient()
        try configure(client, fixture)
        let beforeA = try await primary.state().unauthorized
        let beforeB = try await secondary.state().unauthorized
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<16 {
                group.addTask {
                    for iteration in 0..<64 {
                        switch (worker + iteration) % 5 {
                        case 0: try configure(client, fixture)
                        case 1: try configure(client, fixture, secondary: true)
                        case 2: client.clearCredentials()
                        case 3:
                            let url = client.baseURL
                            guard url == nil || url == fixture.primaryURL || url == fixture.secondaryURL else {
                                throw TestFailure(description: "Torn baseURL snapshot")
                            }
                        default:
                            do {
                                let stats = try await client.coreStats()
                                guard stats.bytes == 101 || stats.bytes == 202 else {
                                    throw TestFailure(description: "Invalid concurrent response")
                                }
                            } catch let error as RcloneRCError {
                                switch error {
                                case .configuration, .staleSession: break
                                default: throw error
                                }
                            }
                        }
                        await Task.yield()
                    }
                }
            }
            try await group.waitForAll()
        }
        try configure(client, fixture)
        let statsA = try await client.coreStats()
        try configure(client, fixture, secondary: true)
        let statsB = try await client.coreStats()
        let afterA = try await primary.state().unauthorized
        let afterB = try await secondary.state().unauthorized
        try expect(statsA.bytes == 101 && statsB.bytes == 202, "1,024 concurrent state/transport operations retain valid checked-Sendable state")
        try expect(afterA == beforeA && afterB == beforeB, "atomic configuration never pairs one endpoint with another mount's credentials")
    }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw TestFailure(description: "usage: RCClientIntegrationTests <mock-address-manifest>")
            }
            let fixture = try JSONDecoder().decode(MockFixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let primary = MockControl(baseURL: fixture.primaryURL, username: "drivestream", password: "secret")
            let secondary = MockControl(baseURL: fixture.secondaryURL, username: "second", password: "new-secret")
            try await lifecycleTests(fixture, primary)
            try await endpointTests(fixture, primary)
            try await errorAndRetryTests(fixture, primary)
            try await redirectTests(fixture, primary, secondary)
            try await cancellationAndGenerationTests(fixture, primary)
            try await concurrencyTests(fixture, primary, secondary)
            print("All RcloneRCClient integration tests passed (Swift 6, complete strict concurrency, warnings as errors).")
        } catch {
            FileHandle.standardError.write(Data("FAIL: RC integration error: \(error)\n".utf8))
            exit(1)
        }
    }
}
