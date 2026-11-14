import Darwin
import Foundation

/// Sets the Finder `kHasCustomIcon` bit without requiring the optional `SetFile`
/// command-line tool. Some FUSE/NFS backends reject FinderInfo writes; that is safe
/// to ignore, and Finder still recognises `.VolumeIcon.icns` on many volume types.
enum VolumeIconFlag {
    static func markCustomIcon(at path: String) {
        let attribute = "com.apple.FinderInfo"
        var info = [UInt8](repeating: 0, count: 32)
        let readCount = path.withCString { pathPointer in
            attribute.withCString { namePointer in
                getxattr(pathPointer, namePointer, &info, info.count, 0, 0)
            }
        }
        if readCount <= 0 {
            info = [UInt8](repeating: 0, count: 32)
        }
        // Finder flags are stored big-endian at byte offset 8. kHasCustomIcon = 0x0400.
        info[8] |= 0x04
        _ = path.withCString { pathPointer in
            attribute.withCString { namePointer in
                setxattr(pathPointer, namePointer, &info, info.count, 0, 0)
            }
        }
    }
}
