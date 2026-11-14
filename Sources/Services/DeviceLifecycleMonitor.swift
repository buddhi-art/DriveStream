import AppKit
import Foundation
import Network

enum ConnectivityState: String, Equatable, Sendable {
    case unknown, available, unavailable
}

enum DeviceLifecycleEvent: Equatable, Sendable {
    case network(ConnectivityState)
    case willSleep
    case didWake
}

/// Each instance represents a single monitoring session: cancelled Network
/// framework monitors cannot be restarted. Callbacks may arrive on any queue.
@MainActor
protocol DeviceNetworkPathMonitoring: AnyObject {
    func start(handler: @escaping @Sendable (ConnectivityState) -> Void)
    func cancel()
}

@MainActor
protocol DeviceLifecycleObservation: AnyObject {
    func cancel()
}

@MainActor
protocol DeviceLifecycleNotificationObserving {
    func observe(_ name: Notification.Name, handler: @escaping @Sendable () -> Void) -> any DeviceLifecycleObservation
}

@MainActor
private final class SystemNetworkPathMonitor: DeviceNetworkPathMonitoring {
    private let monitor = NWPathMonitor()

    func start(handler: @escaping @Sendable (ConnectivityState) -> Void) {
        monitor.pathUpdateHandler = { path in
            handler(path.status == .satisfied ? .available : .unavailable)
        }
        monitor.start(queue: DispatchQueue(label: "com.drivestream.network-path", qos: .utility))
    }

    func cancel() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}

@MainActor
private struct WorkspaceLifecycleNotifications: DeviceLifecycleNotificationObserving {
    func observe(_ name: Notification.Name, handler: @escaping @Sendable () -> Void) -> any DeviceLifecycleObservation {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() }
        return WorkspaceLifecycleObservation(center: center, token: token)
    }
}

@MainActor
private final class WorkspaceLifecycleObservation: DeviceLifecycleObservation {
    private let center: NotificationCenter
    private var token: (any NSObjectProtocol)?

    init(center: NotificationCenter, token: any NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    func cancel() {
        guard let token else { return }
        self.token = nil
        center.removeObserver(token)
    }

    isolated deinit { cancel() }
}

/// Observes the machine, not Google authentication. A satisfied path is not proof
/// that Drive can be reached. Consumers preserve cached volumes while offline.
@MainActor
final class DeviceLifecycleMonitor {
    typealias Delivery = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    private let handler: @MainActor @Sendable (DeviceLifecycleEvent) -> Void
    private let makeMonitor: @MainActor () -> any DeviceNetworkPathMonitoring
    private let notifications: any DeviceLifecycleNotificationObserving
    private let deliver: Delivery
    private var monitor: (any DeviceNetworkPathMonitoring)?
    private var observers: [any DeviceLifecycleObservation] = []
    private var generation: UUID?

    convenience init(handler: @escaping @MainActor @Sendable (DeviceLifecycleEvent) -> Void) {
        self.init(makeMonitor: { SystemNetworkPathMonitor() }, notifications: WorkspaceLifecycleNotifications(), handler: handler)
    }

    /// Injection keeps offline regressions independent of network, workspace, and
    /// executor timing. Production always schedules delivery on the main actor.
    init(
        makeMonitor: @escaping @MainActor () -> any DeviceNetworkPathMonitoring,
        notifications: any DeviceLifecycleNotificationObserving,
        deliver: @escaping Delivery = { action in Task { @MainActor in action() } },
        handler: @escaping @MainActor @Sendable (DeviceLifecycleEvent) -> Void
    ) {
        self.makeMonitor = makeMonitor
        self.notifications = notifications
        self.deliver = deliver
        self.handler = handler
    }

    func start() {
        guard generation == nil else { return }
        let generation = UUID()
        self.generation = generation
        let monitor = makeMonitor()
        self.monitor = monitor
        let deliver = self.deliver
        monitor.start { [weak self] state in
            deliver { [weak self] in self?.receive(.network(state), generation: generation) }
        }
        observers = [
            observe(NSWorkspace.willSleepNotification, event: .willSleep, generation: generation),
            observe(NSWorkspace.didWakeNotification, event: .didWake, generation: generation)
        ]
    }

    func stop() {
        // Invalidate first: cancellation/observer removal need not retract already
        // queued callbacks, including callbacks delivered after a later start().
        generation = nil
        monitor?.cancel()
        monitor = nil
        for observer in observers { observer.cancel() }
        observers.removeAll()
    }

    private func observe(_ name: Notification.Name, event: DeviceLifecycleEvent, generation: UUID) -> any DeviceLifecycleObservation {
        let deliver = self.deliver
        return notifications.observe(name) { [weak self] in
            deliver { [weak self] in self?.receive(event, generation: generation) }
        }
    }

    private func receive(_ event: DeviceLifecycleEvent, generation: UUID) {
        guard self.generation == generation else { return }
        handler(event)
    }

    isolated deinit { stop() }
}
