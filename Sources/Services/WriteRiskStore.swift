import Foundation

/// A small local recovery warning, not a cloud-acknowledgement journal. Keep a
/// known pending/error marker across app restarts; only fresh observed idle clears
/// it. Cache files themselves are never deleted by this store.
enum WriteRiskStore {
    private static let name = "pending-writes.json"

    static func load(paths: DriveStreamPaths) -> UploadSafetySnapshot? {
        let url = paths.applicationSupportDirectory.appendingPathComponent(name)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024 + 1), data.count <= 64 * 1024 else { return nil }
        return try? JSONDecoder().decode(UploadSafetySnapshot.self, from: data)
    }

    @discardableResult
    static func record(_ snapshot: UploadSafetySnapshot, paths: DriveStreamPaths) -> Bool {
        let url = paths.applicationSupportDirectory.appendingPathComponent(name)
        do {
            if snapshot.state == .idleObserved {
                // Store an observed-idle marker atomically instead of removing an
                // unchecked computed target during a concurrent shutdown.
                try ServiceFileSafety.atomicWrite(try JSONEncoder().encode(snapshot), to: url)
            } else if snapshot.checkedAt != nil || snapshot.state == .blocked {
                try ServiceFileSafety.atomicWrite(try JSONEncoder().encode(snapshot), to: url)
            }
            return true
        } catch {
            NSLog("[DriveStream] Could not persist the write-recovery warning: %@", error.localizedDescription)
            return false
        }
    }
}
