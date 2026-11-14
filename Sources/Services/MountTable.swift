import Foundation

/// A failed inspection is not evidence that a volume has detached. Cleanup treats
/// unknown presence conservatively so it never drops process/mount ownership early.
enum MountPresence: Equatable, Sendable {
    case mounted
    case unmounted
    case unknown

    var mayBeMounted: Bool { self != .unmounted }
}

enum MountTable {
    static func presence(path: String) async -> MountPresence {
        guard path.hasPrefix("/"), path != "/" else { return .unmounted }
        do {
            let result = try await CommandRunner.run(executable: "/sbin/mount", timeout: 10)
            return containsMount(path: path, table: result.standardOutput) ? .mounted : .unmounted
        } catch {
            return .unknown
        }
    }

    static func isActive(path: String) async -> Bool {
        await presence(path: path).mayBeMounted
    }

    static func containsMount(path: String, table: String) -> Bool {
        let target = canonicalPath(path)
        for rawLine in table.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let separator = line.range(of: " on ") else { continue }
            let remainder = line[separator.upperBound...]
            let mountPoint = remainder.range(of: " (").map { String(remainder[..<$0.lowerBound]) } ?? String(remainder)
            let normalized = mountPoint
                .replacingOccurrences(of: "\\040", with: " ")
                .replacingOccurrences(of: "\\011", with: "\t")
                .trimmingCharacters(in: .whitespaces)
            if canonicalPath(normalized) == target { return true }
        }
        return false
    }

    static func unmountIfUnused(path: String) async -> Bool {
        guard path.hasPrefix("/"), path != "/" else { return false }
        let target = canonicalPath(path)
        guard target != "/", target != "/Volumes" else { return false }
        let result = try? await CommandRunner.run(executable: "/usr/sbin/diskutil", arguments: ["unmount", target], timeout: 30)
        return result?.succeeded == true
    }

    static func forceUnmount(path: String) async -> Bool {
        guard path.hasPrefix("/"), path != "/" else { return false }
        let target = canonicalPath(path)
        guard target != "/", target != "/Volumes" else { return false }
        let diskutil = try? await CommandRunner.run(
            executable: "/usr/sbin/diskutil", arguments: ["unmount", "force", target], timeout: 30
        )
        if diskutil?.succeeded == true { return true }
        let umount = try? await CommandRunner.run(executable: "/sbin/umount", arguments: ["-f", target], timeout: 30)
        return umount?.succeeded == true
    }

    /// /sbin/mount reports /private/tmp where callers may use /tmp.
    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
