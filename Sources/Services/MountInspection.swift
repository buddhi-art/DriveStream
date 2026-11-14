import Foundation

/// The controller owns lifecycle decisions, while the platform inspector owns
/// observation and detachment. A test inspector can model a busy/stale filesystem
/// without ever mounting or force-unmounting anything on the developer's Mac.
protocol MountInspecting: Sendable {
    func isActive(path: String) async -> Bool
    func forceUnmount(path: String) async -> Bool
    func unmountIfUnused(path: String) async -> Bool
}

extension MountInspecting {
    // A custom inspector must explicitly implement safe detachment. Never turn a
    // missing normal-unmount implementation into a force-unmount automatically.
    func unmountIfUnused(path: String) async -> Bool { false }
}

struct SystemMountInspector: MountInspecting {
    func isActive(path: String) async -> Bool { await MountTable.isActive(path: path) }
    func forceUnmount(path: String) async -> Bool { await MountTable.forceUnmount(path: path) }
    func unmountIfUnused(path: String) async -> Bool { await MountTable.unmountIfUnused(path: path) }
}
