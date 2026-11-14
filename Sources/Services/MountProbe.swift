import Darwin
import Foundation

enum MountProbe {
    /// A cheap way to detect a freshly attached macFUSE/NFS filesystem even if the
    /// mount table command is momentarily unavailable.
    static func filesystemType(atPath path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_fstypename) { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
    }
}
