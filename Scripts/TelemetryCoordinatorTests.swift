import Foundation

private struct TelemetryFailure: Error, CustomStringConvertible { let description: String }
private struct MockAddresses: Decodable { let primaryURL: URL; let secondaryURL: URL }

@MainActor
private final class TelemetryEvents {
    var activities: [TelemetrySnapshot] = []
    var quotas: [RcloneAbout] = []
    var warnings: [String?] = []
    var retrying: [Bool] = []
    var totalEvents = 0

    func record(_ update: MountTelemetryCoordinator.Update) {
        totalEvents += 1
        switch update {
        case .activity(let snapshot, _): activities.append(snapshot)
        case .quota(let value): quotas.append(value)
        case .activityUnavailable(let warning): warnings.append(warning)
        case .quotaUnavailable: break
        case .retrying(let active): retrying.append(active)
        }
    }
}

@main
@MainActor
struct TelemetryCoordinatorTests {
    static func main() async {
        do { try await run() }
        catch {
            try? FileHandle.standardError.write(contentsOf: Data("FAIL: telemetry coordinator: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw TelemetryFailure(description: "Missing private mock-address manifest") }
        let addresses = try JSONDecoder().decode(MockAddresses.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let first = RcloneRCClient()
        try first.configure(baseURL: addresses.primaryURL, username: "drivestream", password: "secret")
        let second = RcloneRCClient()
        try second.configure(baseURL: addresses.secondaryURL, username: "second", password: "new-secret")
        let coordinator = MountTelemetryCoordinator()
        defer { coordinator.stop() }
        let events = TelemetryEvents()
        var checks = 0
        func expect(_ value: Bool, _ message: String) throws {
            guard value else { throw TelemetryFailure(description: message) }
            checks += 1
            print("PASS: " + message)
        }
        let initial = TelemetrySnapshot(about: RcloneAbout(total: 12345))
        coordinator.start(session: .init(client: first, remote: "gdrive:", quotaRemote: "gdrive:", remoteNames: ["gdrive"]),
                          initialSnapshot: initial, networkAvailable: false, onUpdate: events.record)
        try await waitFor("first local activity sample") { !events.activities.isEmpty }
        try expect(events.activities.last?.core?.bytes == 101, "First session publishes its own authenticated activity")
        try expect(events.activities.last?.about?.total == 12345, "Preflight quota is retained in the initial activity snapshot")
        coordinator.requestQuotaRefresh()
        try await Task.sleep(for: .milliseconds(100))
        let offlineQuotaRequests = try await count("/operations/about", at: addresses.primaryURL)
        try expect(offlineQuotaRequests == 0, "Offline path disables quota requests, not local activity")

        coordinator.setNetworkAvailable(true)
        coordinator.requestQuotaRefresh()
        try await waitFor("first quota") { events.quotas.count == 1 }
        try expect(events.quotas.last?.total == 5_000_000_000_000, "Quota is published through its separate event")

        // Delay an old quota, cancel it via network loss, and start a replacement.
        let quotaBefore = try await count("/operations/about", at: addresses.primaryURL)
        try await control("/operations/about", behaviors: [["delay": 0.65, "raw": #"{"total":999}"#]], at: addresses.primaryURL)
        coordinator.requestQuotaRefresh()
        try await waitFor("old delayed quota begins") { try await count("/operations/about", at: addresses.primaryURL) > quotaBefore }
        coordinator.setNetworkAvailable(false)
        coordinator.setNetworkAvailable(true)
        coordinator.requestQuotaRefresh()
        try await waitFor("replacement quota") { events.quotas.count == 2 }
        try await Task.sleep(for: .milliseconds(750))
        try expect(events.quotas.count == 2 && events.quotas.allSatisfy { $0.total != 999 }, "Cancelled quota cannot publish into or release the replacement request")

        let firstCount = try await count("/core/stats", at: addresses.primaryURL)
        let activityBefore = events.activities.count
        try await control("/core/stats", behaviors: [["delay": 0.65, "raw": #"{"bytes":999,"transferring":[]}"#]], at: addresses.primaryURL)
        coordinator.refreshNow()
        try await waitFor("old delayed activity begins") { try await count("/core/stats", at: addresses.primaryURL) > firstCount }
        coordinator.refreshNow()
        try await waitFor("replacement activity") { events.activities.count > activityBefore }
        try await Task.sleep(for: .milliseconds(750))
        try expect(events.activities.allSatisfy { $0.core?.bytes != 999 }, "Retry Now discards a superseded activity sample")
        try expect(events.retrying.contains(true) && events.retrying.last == false, "Retry state finishes for the current request only")

        let lastGood = events.activities.last
        let activityBeforeFailure = events.activities.count
        let warningsBefore = events.warnings.count
        try await control("/core/stats", behaviors: [["status": 401]], at: addresses.primaryURL)
        coordinator.refreshNow()
        try await waitFor("permanent read warning") { events.warnings.count > warningsBefore }
        try expect(events.activities.count == activityBeforeFailure && events.activities.last?.lastUpdated == lastGood?.lastUpdated,
                   "A failed read cannot publish a fresh empty sample or change the last-good timestamp")
        try expect(events.warnings.last.flatMap { $0 } != nil, "Permanent authentication errors surface a warning without blind retries")
        coordinator.refreshNow()
        try await waitFor("successful recovery") { events.activities.count > activityBeforeFailure }
        try expect(events.activities.last?.core?.bytes == 101, "A successful explicit retry restores current activity")

        let requestsBeforeStop = try await count("/core/stats", at: addresses.primaryURL)
        try await control("/core/stats", behaviors: [["delay": 0.65, "raw": #"{"bytes":777,"transferring":[]}"#]], at: addresses.primaryURL)
        coordinator.refreshNow()
        try await waitFor("delayed request before stop") { try await count("/core/stats", at: addresses.primaryURL) > requestsBeforeStop }
        coordinator.stop()
        let eventCountAtStop = events.totalEvents
        try await Task.sleep(for: .milliseconds(750))
        try expect(events.totalEvents == eventCountAtStop, "Stopped coordinator rejects all queued activity/quota callbacks")
        let newSession = TelemetryEvents()
        coordinator.start(session: .init(client: second, remote: "gdrive:", quotaRemote: "gdrive:", remoteNames: ["gdrive"]),
                          initialSnapshot: TelemetrySnapshot(), networkAvailable: false, onUpdate: newSession.record)
        try await waitFor("replacement session activity") { !newSession.activities.isEmpty }
        try expect(newSession.activities.allSatisfy { $0.core?.bytes == 202 }, "Restarted coordinator publishes only the new session's samples")
        try expect(events.totalEvents == eventCountAtStop, "A replacement session never invokes the prior owner's callback")
        coordinator.stop()
        print("All \(checks) telemetry coordinator regressions passed.")
    }

    static func waitFor(_ name: String, condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TelemetryFailure(description: "Timed out: " + name)
    }

    static func control(_ endpoint: String, behaviors: [[String: Any]], at base: URL) async throws {
        var request = URLRequest(url: base.appendingPathComponent("_test/control"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("drivestream:secret".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["endpoint": endpoint, "behaviors": behaviors])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TelemetryFailure(description: "Mock control failed") }
    }

    static func count(_ endpoint: String, at base: URL) async throws -> Int {
        var request = URLRequest(url: base.appendingPathComponent("_test/state"))
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let counts = state["counts"] as? [String: Int] else { throw TelemetryFailure(description: "Mock state failed") }
        return counts[endpoint] ?? 0
    }
}
