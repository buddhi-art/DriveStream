import Darwin
import Foundation
import Network

@main
@MainActor
struct ServiceSafetyTests {
    static let root = try! ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-service-tests-")
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "Validation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        pass(message)
    }
    static func pass(_ message: String) {
        checks += 1
        print("PASS: " + message)
    }
    static func main() async throws {
        defer { ServiceFileSafety.removeTemporaryDirectory(root, prefix: "DriveStream-service-tests-") }
        let server = try await HTTPFixture.start()
        defer { server.stop() }
        let fileManager = FileManager.default
        let privateRoot = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-command-test-")
        let privateFile = privateRoot.appendingPathComponent("input")
        try ServiceFileSafety.createPrivateFile(privateFile, data: Data("test".utf8))
        let directoryMode = (try fileManager.attributesOfItem(atPath: privateRoot.path)[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = (try fileManager.attributesOfItem(atPath: privateFile.path)[.posixPermissions] as? NSNumber)?.intValue
        try expect(directoryMode == 0o700 && fileMode == 0o600, "temporary directory 0700 and secret file 0600 from creation")
        ServiceFileSafety.removeTemporaryDirectory(privateRoot, prefix: "DriveStream-command-test-")
        try expect(!fileManager.fileExists(atPath: privateRoot.path), "confined temporary cleanup")

        let hello = try await CommandRunner.run(executable: "/bin/echo", arguments: ["hello"])
        try expect(hello.standardOutput == "hello\n", "ordinary helper stdout captured")
        let input = try await CommandRunner.run(executable: "/usr/bin/tee", input: "private input\n")
        try expect(input.standardOutput == "private input\n", "private stdin file delivered")
        let large = try await CommandRunner.run(executable: "/usr/bin/head", arguments: ["-c", "300000", "/dev/zero"])
        try expect(large.standardOutput.utf8.count == 300000, "300 KB output captured without pipe deadlock")
        do {
            _ = try await CommandRunner.run(executable: "/usr/bin/head", arguments: ["-c", "6000000", "/dev/zero"])
            throw NSError(domain: "Validation", code: 2)
        } catch CommandRunnerError.outputLimitExceeded { pass("oversized helper output rejected with bounded readback") }
        do {
            _ = try await CommandRunner.run(executable: "/bin/sh", arguments: ["-c", "printf 'access_token=VERY_SECRET'; exit 7"])
            throw NSError(domain: "Validation", code: 3)
        } catch let error as CommandRunnerError {
            try expect(!error.localizedDescription.contains("VERY_SECRET"), "failure messages never expose captured secrets")
        }
        do {
            _ = try await CommandRunner.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.2)
            throw NSError(domain: "Validation", code: 4)
        } catch CommandRunnerError.timedOut { pass("helper timeout terminates process") }
        let pidFile = root.appendingPathComponent("cancel.pid")
        let clock = ContinuousClock()
        let cancellationStart = clock.now
        let cancelled = Task {
            try await CommandRunner.run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; printf '%s' $$ > '\(pidFile.path)'; exec /bin/sleep 30"])
        }
        try await Task.sleep(for: .milliseconds(200))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw NSError(domain: "Validation", code: 5)
        } catch is CancellationError { pass("parent cancellation reaches detached helper") }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = Int32(pidText)!
        try expect(kill(pid, 0) == -1 && errno == ESRCH, "SIGTERM-ignoring child killed before cancellation returns")
        try expect(cancellationStart.duration(to: clock.now) < .seconds(5), "cancellation shutdown bounded below five seconds")

        let configPaths = DriveStreamPaths(applicationSupportDirectory: root.appendingPathComponent("support"), homeDirectory: root.appendingPathComponent("home"))
        try configPaths.prepareFileSystem()
        let service = RcloneConfigService(paths: configPaths, keychain: KeychainHelper(service: "com.drivestream.validation.unused"))
        try ServiceFileSafety.atomicWrite(Data("[other]\ntype = local\n\n[drive]\nteam_drive = preserved\n".utf8), to: configPaths.configFile)
        let token = #"{"access_token":"test","refresh_token":"not-a-live-token"}"#
        try service.writeDriveRemote(remoteName: "drive", token: token, clientID: "custom-client", clientSecret: "custom-secret")
        var configText = try String(contentsOf: configPaths.configFile, encoding: .utf8)
        try expect(configText.contains("[other]") && configText.contains("team_drive = preserved") && configText.contains("custom-secret"), "atomic Drive writer preserves unrelated remotes and custom OAuth")
        try service.writeDriveRemote(remoteName: "drive", token: token, clientID: "", clientSecret: "")
        configText = try String(contentsOf: configPaths.configFile, encoding: .utf8)
        try expect(!configText.contains("client_secret") && configText.contains("token = " + token), "default OAuth clears custom credentials without invoking authorize")
        try expect((try fileManager.attributesOfItem(atPath: configPaths.configFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "atomic config remains 0600")
        for name in ["bad\n[injected]", "bad]", "bad[", "bad\rname", "bad\0name", "-option"] {
            do {
                try service.writeDriveRemote(remoteName: name, token: token, clientID: "", clientSecret: "")
                throw NSError(domain: "Validation", code: 6)
            } catch is RcloneConfigError { pass("invalid remote/section injection rejected") }
        }
        do {
            try service.writeDriveRemote(remoteName: "drive", token: "token\n[injected]", clientID: "", clientSecret: "")
            throw NSError(domain: "Validation", code: 7)
        } catch is RcloneConfigError { pass("INI credential newline injection rejected") }
        try expect(RcloneConfigService.extractTokenJSON(from: "noise {\"access_token\":\"test\",\"nested\":\"{quoted}\"} end") != nil, "nonisolated OAuth token parser handles braces in strings")

        let right = String(repeating: "a", count: 64)
        let wrong = String(repeating: "b", count: 64)
        let sums = wrong + "  debug.tbz\n" + right + "  macfuse.dmg\n"
        try expect(DependencyArchiveSafety.checksum(in: sums, for: "macfuse.dmg") == right, "macFUSE checksum selects exact DMG, never first digest")
        try expect(DependencyArchiveSafety.checksum(in: sums, for: "other.dmg") == nil, "missing exact checksum rejected")
        try expect(DependencyArchiveSafety.checksum(in: sums + right + "  macfuse.dmg\n", for: "macfuse.dmg") == nil, "ambiguous duplicate checksum rejected")
        // Fixed ZIP fixtures: no external tools, network, or executable payloads.
        let fixtures: [String: String] = [
            "safe.zip": "UEsDBBQAAAAAACm7ZV0gftKdGwAAABsAAAAfAAAAcmNsb25lLXYxLjc1LjItb3N4LWFybTY0L3JjbG9uZWZpeHR1cmUtb25seS1ub3QtZXhlY3V0YWJsZVBLAQIUAxQAAAAAACm7ZV0gftKdGwAAABsAAAAfAAAAAAAAAAAAAACAAQAAAAByY2xvbmUtdjEuNzUuMi1vc3gtYXJtNjQvcmNsb25lUEsFBgAAAAABAAEATQAAAFgAAAAAAA==",
            "traversal.zip": "UEsDBBQAAAAAACm7ZV0gftKdGwAAABsAAAAfAAAAcmNsb25lLXYxLjc1LjItb3N4LWFybTY0L3JjbG9uZWZpeHR1cmUtb25seS1ub3QtZXhlY3V0YWJsZVBLAwQUAAAAAAApu2Vd+zkrggMAAAADAAAACgAAAC4uL291dHNpZGViYWRQSwECFAMUAAAAAAApu2VdIH7SnRsAAAAbAAAAHwAAAAAAAAAAAAAAgAEAAAAAcmNsb25lLXYxLjc1LjItb3N4LWFybTY0L3JjbG9uZVBLAQIUAxQAAAAAACm7ZV37OSuCAwAAAAMAAAAKAAAAAAAAAAAAAACAAVgAAAAuLi9vdXRzaWRlUEsFBgAAAAACAAIAhQAAAIMAAAAAAA==",
            "symlink.zip": "UEsDBBQAAAAAAAAAIQAKuR8pCwAAAAsAAAAfAAAAcmNsb25lLXYxLjc1LjItb3N4LWFybTY0L3JjbG9uZS9ldGMvcGFzc3dkUEsBAhQDFAAAAAAAAAAhAAq5HykLAAAACwAAAB8AAAAAAAAAAAAAAP+hAAAAAHJjbG9uZS12MS43NS4yLW9zeC1hcm02NC9yY2xvbmVQSwUGAAAAAAEAAQBNAAAASAAAAAAA",
            "duplicate.zip": "UEsDBBQAAAAAACm7ZV0gftKdGwAAABsAAAAfAAAAcmNsb25lLXYxLjc1LjItb3N4LWFybTY0L3JjbG9uZWZpeHR1cmUtb25seS1ub3QtZXhlY3V0YWJsZVBLAwQUAAAAAAApu2VdG4FHEgkAAAAJAAAAHwAAAHJjbG9uZS12MS43NS4yLW9zeC1hcm02NC9yY2xvbmVkdXBsaWNhdGVQSwECFAMUAAAAAAApu2VdIH7SnRsAAAAbAAAAHwAAAAAAAAAAAAAAgAEAAAAAcmNsb25lLXYxLjc1LjItb3N4LWFybTY0L3JjbG9uZVBLAQIUAxQAAAAAACm7ZV0bgUcSCQAAAAkAAAAfAAAAAAAAAAAAAACAAVgAAAByY2xvbmUtdjEuNzUuMi1vc3gtYXJtNjQvcmNsb25lUEsFBgAAAAACAAIAmgAAAJ4AAAAAAA=="
        ]
        for (name, encoded) in fixtures {
            try ServiceFileSafety.createPrivateFile(root.appendingPathComponent(name), data: Data(base64Encoded: encoded)!)
        }
        let member = try DependencyArchiveSafety.rcloneMember(in: root.appendingPathComponent("safe.zip"), version: "v1.75.2", architecture: "arm64")
        try expect(member == "rclone-v1.75.2-osx-arm64/rclone", "valid ZIP selects exact executable member")
        let hashInput = root.appendingPathComponent("hash-input")
        try ServiceFileSafety.createPrivateFile(hashInput, data: Data("abc".utf8))
        let digest = try await DependencyArchiveSafety.sha256(of: hashInput)
        try expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "streaming SHA256 matches standard known vector")
        for name in ["traversal.zip", "symlink.zip", "duplicate.zip"] {
            do {
                _ = try DependencyArchiveSafety.rcloneMember(in: root.appendingPathComponent(name), version: "v1.75.2", architecture: "arm64")
                throw NSError(domain: "Validation", code: 8)
            } catch is DependencyError { pass("unsafe ZIP " + name + " rejected") }
        }
        do {
            let base = server.baseURL.absoluteString
            let destination = root.appendingPathComponent("download.bin")
            try ServiceFileSafety.atomicWrite(Data("ORIGINAL".utf8), to: destination)
            do {
                _ = try await FileDownloader().download(from: URL(string: base + "/missing")!, to: destination)
                throw NSError(domain: "Validation", code: 9)
            } catch FileDownloadError.httpStatus(let status) { try expect(status == 404, "HTTP failure reported before replacing destination") }
            try expect(try String(contentsOf: destination, encoding: .utf8) == "ORIGINAL", "HTTP error preserves existing download")
            let downloader = FileDownloader()
            _ = try await downloader.download(from: URL(string: base + "/ok")!, to: destination)
            try expect(try String(contentsOf: destination, encoding: .utf8) == "NEW", "successful download atomically replaces destination")
            do {
                _ = try await downloader.download(from: URL(string: base + "/ok")!, to: destination)
                throw NSError(domain: "Validation", code: 10)
            } catch FileDownloadError.alreadyUsed { pass("downloader enforces one-shot lifecycle") }
            let slow = Task { try await FileDownloader().download(from: URL(string: base + "/slow")!, to: destination) }
            try await Task.sleep(for: .milliseconds(100))
            slow.cancel()
            do { _ = try await slow.value; throw NSError(domain: "Validation", code: 11) }
            catch is CancellationError { pass("active download cancelled without awaiting delegate completion") }
            try expect(try String(contentsOf: destination, encoding: .utf8) == "NEW", "cancelled download preserves destination")
            let concurrentDownloader = FileDownloader()
            var firstFinished = false
            let first = Task {
                defer { firstFinished = true }
                return try await concurrentDownloader.download(from: URL(string: base + "/slow")!, to: destination)
            }
            try await Task.sleep(for: .milliseconds(100))
            do {
                _ = try await concurrentDownloader.download(from: URL(string: base + "/ok")!, to: destination)
                throw NSError(domain: "Validation", code: 13)
            } catch FileDownloadError.alreadyUsed { pass("concurrent downloader reuse rejected") }
            try await Task.sleep(for: .milliseconds(100))
            try expect(!firstFinished, "discarded duplicate session cannot complete original download")
            first.cancel()
            do { _ = try await first.value; throw NSError(domain: "Validation", code: 14) }
            catch is CancellationError { pass("original download remains independently cancellable after misuse") }
            for _ in 0..<50 {
                let task = Task { try await FileDownloader().download(from: URL(string: base + "/ok")!, to: destination) }
                task.cancel()
                do { _ = try await task.value; throw NSError(domain: "Validation", code: 12) }
                catch is CancellationError { checks += 1 }
            }
            print("PASS: 50 immediate cancellation races resume exactly once")
        }
        print("ALL SERVICE SAFETY TESTS PASSED (\(checks) checks)")
    }
}


/// Test-only HTTP endpoint bound to an OS-assigned loopback port. Slow responses
/// send headers but never a body, so cancellation can be verified deterministically.
@MainActor
final class HTTPFixture {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var startup: CheckedContinuation<URL, any Error>?

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> HTTPFixture {
        let fixture = try HTTPFixture()
        _ = try await withCheckedThrowingContinuation { continuation in
            fixture.startup = continuation
            fixture.listener.stateUpdateHandler = { [weak fixture] state in
                Task { @MainActor in fixture?.updated(state) }
            }
            fixture.listener.newConnectionHandler = { [weak fixture] connection in
                Task { @MainActor in fixture?.accept(connection) }
            }
            fixture.listener.start(queue: .global(qos: .utility))
        }
        return fixture
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
    }

    func stop() {
        startup?.resume(throwing: CancellationError())
        startup = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
        listener.cancel()
    }

    private func updated(_ state: NWListener.State) {
        switch state {
        case .ready:
            startup?.resume(returning: baseURL)
            startup = nil
        case .failed(let error):
            startup?.resume(throwing: error)
            startup = nil
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .global(qos: .utility))
        Self.receiveRequest(connection)
    }

    nonisolated private static func receiveRequest(_ connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, _ in
            guard let data, !data.isEmpty, accumulated.count + data.count <= 8192 else { connection.cancel(); return }
            let combined = accumulated + data
            let request = String(decoding: combined, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if complete { connection.cancel() }
                else { receiveRequest(connection, accumulated: combined) }
                return
            }
            let missing = request.hasPrefix("GET /missing ")
            let slow = request.hasPrefix("GET /slow ")
            let body = missing ? "BAD" : "NEW"
            let status = missing ? "404 Not Found" : "200 OK"
            let length = slow ? 1_000_000 : 3
            let response = "HTTP/1.1 \(status)\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n" + (slow ? "" : body)
            connection.send(content: Data(response.utf8), isComplete: !slow, completion: .contentProcessed { _ in
                if !slow { connection.cancel() }
            })
        }
    }
}
