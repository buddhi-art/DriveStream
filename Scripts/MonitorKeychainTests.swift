// Deterministic offline tests. No system Keychain operations, authentication UI,
// real network monitors, workspace notifications, Google, rclone, or user files.
import AppKit
import Foundation
import os
import Security

private final class QueuedDelivery: Sendable {
    private let actions = OSAllocatedUnfairLock(initialState: [@MainActor @Sendable () -> Void]())

    func submit(_ action: @escaping @MainActor @Sendable () -> Void) {
        actions.withLock { $0.append(action) }
    }

    @MainActor func drain() {
        let pending = actions.withLock { actions in
            let pending = actions
            actions.removeAll()
            return pending
        }
        for action in pending { action() }
    }
}

@MainActor
private final class FakePathMonitor: DeviceNetworkPathMonitoring {
    var starts = 0
    var cancels = 0
    var callback: (@Sendable (ConnectivityState) -> Void)?

    func start(handler: @escaping @Sendable (ConnectivityState) -> Void) {
        starts += 1
        callback = handler
    }

    func cancel() { cancels += 1 }
    // Deliberately retain the callback after cancellation to simulate queued work.
    func emit(_ state: ConnectivityState) { callback?(state) }
}

@MainActor
private final class FakePathFactory {
    var monitors: [FakePathMonitor] = []
    func make() -> any DeviceNetworkPathMonitoring {
        let monitor = FakePathMonitor()
        monitors.append(monitor)
        return monitor
    }
}

@MainActor
private final class FakeObservation: DeviceLifecycleObservation {
    let name: Notification.Name
    let callback: @Sendable () -> Void
    var cancels = 0

    init(name: Notification.Name, callback: @escaping @Sendable () -> Void) {
        self.name = name
        self.callback = callback
    }
    func cancel() { cancels += 1 }
}

@MainActor
private final class FakeNotifications: DeviceLifecycleNotificationObserving {
    var observations: [FakeObservation] = []

    func observe(_ name: Notification.Name, handler: @escaping @Sendable () -> Void) -> any DeviceLifecycleObservation {
        let observation = FakeObservation(name: name, callback: handler)
        observations.append(observation)
        return observation
    }
}

@MainActor
private final class EventRecorder {
    var events: [DeviceLifecycleEvent] = []
    var onEvent: (@MainActor (DeviceLifecycleEvent) -> Void)?
    func receive(_ event: DeviceLifecycleEvent) {
        events.append(event)
        onEvent?(event)
    }
}

private final class FakeSecItems: KeychainSecItemOperations {
    enum Operation: Hashable, Sendable { case update, add, read, presence, delete }
    struct Call: Equatable, Sendable {
        let operation: Operation
        let query: KeychainItemQuery
    }
    struct State: Sendable {
        var values: [KeychainItemQuery: Data] = [:]
        var responses: [Operation: [OSStatus]] = [:]
        var calls: [Call] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var snapshot: State { state.withLock { $0 } }

    func seed(_ data: Data, query: KeychainItemQuery) {
        state.withLock { $0.values[query] = data }
    }

    func respond(_ operation: Operation, _ statuses: [OSStatus]) {
        state.withLock { $0.responses[operation] = statuses }
    }

    private func status(_ operation: Operation, _ query: KeychainItemQuery, default fallback: OSStatus, state: inout State) -> OSStatus {
        state.calls.append(Call(operation: operation, query: query))
        guard var responses = state.responses[operation], !responses.isEmpty else { return fallback }
        let status = responses.removeFirst()
        state.responses[operation] = responses
        return status
    }

    func update(_ query: KeychainItemQuery, data: Data) -> OSStatus {
        state.withLock { state in
            let result = status(.update, query, default: state.values[query] == nil ? errSecItemNotFound : errSecSuccess, state: &state)
            if result == errSecSuccess { state.values[query] = data }
            return result
        }
    }

    func add(_ query: KeychainItemQuery, data: Data) -> OSStatus {
        state.withLock { state in
            let result = status(.add, query, default: state.values[query] == nil ? errSecSuccess : errSecDuplicateItem, state: &state)
            if result == errSecSuccess { state.values[query] = data }
            return result
        }
    }

    func copyMatching(_ query: KeychainItemQuery, returning: KeychainMatchResult) -> KeychainCopyResult {
        state.withLock { state in
            let result = status(returning == .secret ? .read : .presence, query,
                default: state.values[query] == nil ? errSecItemNotFound : errSecSuccess, state: &state)
            return KeychainCopyResult(status: result, data: returning == .secret ? state.values[query] : nil)
        }
    }

    func delete(_ query: KeychainItemQuery) -> OSStatus {
        state.withLock { state in
            let result = status(.delete, query, default: state.values[query] == nil ? errSecItemNotFound : errSecSuccess, state: &state)
            if result == errSecSuccess { state.values[query] = nil }
            return result
        }
    }
}

@main
@MainActor
private struct MonitorKeychainTests {
    static var checks = 0
    static let service = "com.drivestream.offline-test"

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() {
            try? FileHandle.standardError.write(contentsOf: Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
        checks += 1
    }

    static func expectStatus(_ status: OSStatus, _ message: String, body: () throws -> Void) {
        do {
            try body()
            expect(false, "\(message): expected status \(status)")
        } catch KeychainError.unexpectedStatus(let actual) {
            expect(actual == status, message)
        } catch {
            expect(false, "\(message): wrong error \(error)")
        }
    }

    static func expectCorruption(_ message: String, body: () throws -> Void) {
        do { try body(); expect(false, message) }
        catch KeychainError.dataCorrupted { expect(true, message) }
        catch { expect(false, "\(message): wrong error") }
    }

    static func query(_ account: String) -> KeychainItemQuery {
        KeychainItemQuery(service: service, account: account)
    }

    static func main() async throws {
        await testMonitorGenerations()
        await testDefaultDelivery()
        testDeallocation()
        testQueryPolicy()
        try testKeychainBasics()
        try testKeychainFailures()
        try testCredentialSnapshots()
        try await testConcurrentBackend()
        print("PASS: \(checks) monitor/Keychain checks; all I/O boundaries are offline fakes.")
    }

    static func testMonitorGenerations() async {
        let factory = FakePathFactory(), notifications = FakeNotifications()
        let delivery = QueuedDelivery(), recorder = EventRecorder()
        let monitor = DeviceLifecycleMonitor(makeMonitor: factory.make, notifications: notifications,
            deliver: delivery.submit, handler: recorder.receive)
        monitor.stop()
        monitor.start()
        monitor.start()
        expect(factory.monitors.count == 1 && factory.monitors[0].starts == 1, "start is idempotent")
        expect(notifications.observations.count == 2, "exactly two workspace observers")
        expect(notifications.observations.map(\.name) == [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification], "workspace names match production")
        let oldPath = factory.monitors[0]
        let oldSleep = notifications.observations[0], oldWake = notifications.observations[1]
        oldPath.emit(.available)
        oldSleep.callback()
        oldWake.callback()
        delivery.drain()
        expect(recorder.events == [.network(.available), .willSleep, .didWake], "current callbacks delivered in order")
        recorder.events.removeAll()

        // Queue all three old callbacks before stop, then deliver after restart.
        oldPath.emit(.unavailable)
        oldSleep.callback()
        oldWake.callback()
        monitor.stop()
        monitor.stop()
        expect(oldPath.cancels == 1, "stop cancels once")
        expect(oldSleep.cancels == 1 && oldWake.cancels == 1, "stop removes both observers once")
        monitor.start()
        expect(factory.monitors.count == 2, "restart creates a fresh path monitor")
        expect(factory.monitors[0] !== factory.monitors[1], "cancelled instance is never reused")
        delivery.drain()
        expect(recorder.events.isEmpty, "already queued old generation events are rejected")

        oldPath.emit(.unavailable)
        oldSleep.callback()
        oldWake.callback()
        delivery.drain()
        expect(recorder.events.isEmpty, "late old path and workspace callbacks are rejected")
        let currentCallback = factory.monitors[1].callback!
        await Task.detached { currentCallback(.available) }.value
        notifications.observations[2].callback()
        notifications.observations[3].callback()
        delivery.drain()
        expect(recorder.events == [.network(.available), .willSleep, .didWake], "new session handles background callback and workspace events")
        recorder.events.removeAll()
        factory.monitors[1].emit(.unavailable)
        monitor.stop()
        delivery.drain()
        expect(recorder.events.isEmpty, "stop rejects queued current session callbacks")
        expect(notifications.observations.allSatisfy { $0.cancels == 1 }, "every observer removed")
    }

    static func testDefaultDelivery() async {
        let factory = FakePathFactory(), notifications = FakeNotifications(), recorder = EventRecorder()
        let monitor = DeviceLifecycleMonitor(makeMonitor: factory.make, notifications: notifications, handler: recorder.receive)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recorder.onEvent = { event in
                expect(event == .network(.available), "default Task delivery ignores stale events")
                recorder.onEvent = nil
                continuation.resume()
            }
            monitor.start()
            factory.monitors[0].emit(.unavailable)
            notifications.observations[0].callback()
            monitor.stop()
            monitor.start()
            factory.monitors[1].emit(.available)
        }
        monitor.stop()
        expect(recorder.events == [.network(.available)], "default main-actor delivery resumes continuation once")
    }

    static func testDeallocation() {
        let factory = FakePathFactory(), notifications = FakeNotifications()
        let delivery = QueuedDelivery(), recorder = EventRecorder()
        var monitor: DeviceLifecycleMonitor? = DeviceLifecycleMonitor(makeMonitor: factory.make, notifications: notifications,
            deliver: delivery.submit, handler: recorder.receive)
        weak let weakMonitor = monitor
        monitor?.start()
        factory.monitors[0].emit(.available)
        monitor = nil
        expect(weakMonitor == nil, "queued callbacks do not retain lifecycle owner")
        expect(factory.monitors[0].cancels == 1, "deinit cancels active monitor")
        expect(notifications.observations.allSatisfy { $0.cancels == 1 }, "deinit removes workspace observers")
        notifications.observations.forEach { $0.callback() }
        delivery.drain()
        expect(recorder.events.isEmpty, "callbacks after deinit are harmless")

        weak var releasedPath: FakePathMonitor?
        let lifecycle = DeviceLifecycleMonitor(makeMonitor: {
            let path = FakePathMonitor()
            releasedPath = path
            return path
        }, notifications: FakeNotifications(), handler: { _ in })
        lifecycle.start()
        expect(releasedPath != nil, "active path monitor is retained by lifecycle")
        lifecycle.stop()
        expect(releasedPath == nil, "stop releases its cancelled path monitor")
    }

    static func testQueryPolicy() {
        let item = query(KeychainAccountName.cryptPassword)
        let attributes = item.attributes
        expect(attributes.count == 3, "legacy identity has no extra policy attributes")
        expect(attributes[kSecClass] as? String == kSecClassGenericPassword as String, "generic password class unchanged")
        expect(attributes[kSecAttrService] as? String == service, "queries remain service-scoped")
        expect(attributes[kSecAttrAccount] as? String == KeychainAccountName.cryptPassword, "queries remain account-scoped")
        for mode in [KeychainMatchResult.secret, .presence] {
            let matching = item.matching(mode)
            expect(matching[kSecMatchLimit] as? String == kSecMatchLimitOne as String, "copy queries match one item")
            expect(matching[kSecUseDataProtectionKeychain] == nil && matching[kSecAttrSynchronizable] == nil,
                "queries do not migrate or fall back between stores")
            expect(matching[kSecAttrAccessible] == nil && matching[kSecAttrAccessControl] == nil && matching[kSecAttrAccess] == nil,
                "legacy ACLs are not overwritten or falsely augmented")
        }
        let presence = item.matching(.presence)
        expect(presence[kSecReturnData] as? Bool == false, "metadata probe never requests secret data")
        expect(presence[kSecUseAuthenticationUI] as? String == kSecUseAuthenticationUISkip as String, "metadata probe explicitly skips authentication UI")
        expect(presence[kSecReturnRef] == nil && presence[kSecReturnPersistentRef] == nil, "metadata probe returns no secret references")
        let secret = item.matching(.secret)
        expect(secret[kSecReturnData] as? Bool == true && secret[kSecUseAuthenticationUI] == nil, "actual reads preserve login Keychain authentication behavior")
    }

    static func testKeychainBasics() throws {
        let backend = FakeSecItems(), account = KeychainAccountName.cryptPassword
        let helper = KeychainHelper(service: service, operations: backend)
        let original = "  secret é 🔑\n"
        try helper.save(original, for: account)
        expect(backend.snapshot.calls.map(\.operation) == [.update, .add], "new secret uses update then add")
        expect(backend.snapshot.calls.allSatisfy { $0.query == query(account) }, "save keeps exact identity")
        try expect(helper.readString(for: account) == original, "Unicode and whitespace round trip without trimming")
        expect(helper.containsValue(for: account), "present metadata reports true")
        expect(backend.snapshot.calls.last?.operation == .presence, "containsValue uses only metadata operation")
        let beforeUpdate = backend.snapshot.calls.count
        try helper.save("replacement", for: account)
        expect(backend.snapshot.calls.count == beforeUpdate + 1, "existing secret updates without delete/recreate")
        try expect(helper.readString(for: account) == "replacement", "updated secret is readable")
        try helper.save("", for: account)
        expect(backend.snapshot.calls.last?.operation == .delete, "empty secret retains explicit deletion semantics")
        try expect(helper.readString(for: account) == nil, "missing read returns nil")
        try helper.delete(for: account)
        expect(!helper.containsValue(for: account), "missing metadata reports false")

        let beforeInvalid = backend.snapshot.calls.count
        for operation in [{ try helper.save("new", for: "") }, { _ = try helper.readString(for: "") }, { try helper.delete(for: "") }] {
            do { try operation(); expect(false, "empty account rejected") }
            catch KeychainError.emptyAccount { expect(true, "empty account rejected") }
        }
        expect(!helper.containsValue(for: ""), "empty account metadata is false")
        expect(backend.snapshot.calls.count == beforeInvalid, "invalid accounts never touch backend")
        backend.seed(Data([0xFF]), query: query(account))
        expectCorruption("invalid UTF-8 is rejected") { _ = try helper.readString(for: account) }
        backend.respond(.read, [errSecSuccess])
        expectCorruption("successful read without data is rejected") { _ = try helper.readString(for: "absent") }
    }

    static func testKeychainFailures() throws {
        let account = KeychainAccountName.cryptPassword, original = Data("original".utf8)
        for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable, errSecMissingEntitlement] {
            let backend = FakeSecItems()
            backend.seed(original, query: query(account))
            let store = KeychainHelper(service: service, operations: backend)
            backend.respond(.update, [status])
            expectStatus(status, "update refusal preserves original status") { try store.save("replacement", for: account) }
            expect(backend.snapshot.calls.map(\.operation) == [.update], "failed update never adds, deletes, or falls back")
            expect(backend.snapshot.values[query(account)] == original, "failed update preserves existing data")
            backend.respond(.read, [status])
            expectStatus(status, "read refusal is not a missing secret") { _ = try store.readString(for: account) }
            backend.respond(.presence, [status])
            let beforePresence = backend.snapshot.calls.count
            expect(!store.containsValue(for: account), "metadata errors conservatively return false")
            expect(backend.snapshot.calls.count == beforePresence + 1, "metadata error never retries secret read or authentication")
            backend.respond(.delete, [status])
            expectStatus(status, "delete refusal surfaces original status") { try store.delete(for: account) }
            expect(backend.snapshot.values[query(account)] == original, "failed delete preserves existing data")
        }
        let backend = FakeSecItems()
        let helper = KeychainHelper(service: service, operations: backend)
        backend.respond(.add, [errSecAuthFailed])
        expectStatus(errSecAuthFailed, "failed insertion surfaces refusal") { try helper.save("new", for: account) }
        expect(backend.snapshot.calls.map(\.operation) == [.update, .add], "failed insertion has no insecure retry")
        expect(backend.snapshot.values.isEmpty, "failed insertion leaves store unchanged")

        let raced = FakeSecItems()
        raced.seed(original, query: query(account))
        let racing = KeychainHelper(service: service, operations: raced)
        raced.respond(.update, [errSecItemNotFound, errSecSuccess])
        raced.respond(.add, [errSecDuplicateItem])
        try racing.save("replacement", for: account)
        expect(raced.snapshot.calls.map(\.operation) == [.update, .add, .update], "duplicate insertion race retries update exactly once")
        expect(raced.snapshot.values[query(account)] == Data("replacement".utf8), "duplicate race finishes write")
        let before = raced.snapshot.calls.count
        raced.respond(.update, [errSecItemNotFound, errSecUserCanceled])
        raced.respond(.add, [errSecDuplicateItem])
        expectStatus(errSecUserCanceled, "duplicate retry cancellation is surfaced") { try racing.save("lost", for: account) }
        expect(raced.snapshot.calls.count == before + 3, "failed duplicate retry is bounded")
        expect(raced.snapshot.values[query(account)] == Data("replacement".utf8), "failed duplicate retry does not destroy existing value")
    }

    static func testCredentialSnapshots() throws {
        let backend = FakeSecItems()
        let store = KeychainHelper(service: service, operations: backend)
        let password = KeychainAccountName.cryptPassword, salt = KeychainAccountName.cryptSaltPassword
        backend.seed(Data("original".utf8), query: query(password))
        let snapshot = try RcloneCredentialSnapshot(accounts: [password, salt], store: store)
        try store.save("new", for: password)
        try store.save("new salt", for: salt)
        try snapshot.restore(to: store)
        try expect(store.readString(for: password) == "original", "real credential snapshot restores original password")
        try expect(store.readString(for: salt) == nil, "real credential snapshot restores absent salt")
        try store.save("new", for: password)
        try store.save("new salt", for: salt)
        backend.respond(.update, [errSecUserCanceled])
        do { try snapshot.restore(to: store); expect(false, "snapshot restoration failure reported") }
        catch RcloneConfigError.keychain { expect(true, "snapshot restoration failure reported") }
        expect(backend.snapshot.values[query(password)] == Data("new".utf8), "failed restoration does not erase current password")
        expect(backend.snapshot.values[query(salt)] == nil, "snapshot still restores other accounts after refusal")
        backend.respond(.read, [errSecAuthFailed])
        let before = backend.snapshot.calls.count
        expectStatus(errSecAuthFailed, "snapshot read refusal is surfaced before mutation") {
            _ = try RcloneCredentialSnapshot(accounts: [password, salt], store: store)
        }
        expect(backend.snapshot.calls.count == before + 1 && backend.snapshot.calls.last?.operation == .read,
            "failed snapshot does not write or migrate anything")
    }

    static func testConcurrentBackend() async throws {
        let backend = FakeSecItems(), helper = KeychainHelper(service: service, operations: backend)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0..<32 {
                group.addTask {
                    let account = "concurrent-\(number)"
                    try helper.save("value-\(number)", for: account)
                    guard try helper.readString(for: account) == "value-\(number)" else { throw KeychainError.dataCorrupted }
                }
            }
            try await group.waitForAll()
        }
        expect(backend.snapshot.values.count == 32, "immutable helper and native-lock fake support concurrent callers")
    }
}
