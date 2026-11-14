import Darwin
import Foundation

/// Reads one private VFS metadata file incrementally. Sparse range arrays can be
/// larger than one page, so 4 KiB is a read chunk, not a format-size assumption.
enum CacheMetadataReader {
    static let readChunkBytes = 4 * 1024
    static let maximumMetadataBytes = 256 * 1024

    enum Record: Equatable, Sendable {
        case metadata(dirty: Bool)
        case finderSidecar
    }

    enum ReadError: Error {
        case unavailable, notRegular, tooLarge, changedDuringRead, malformed
    }

    static func read(at url: URL) throws -> Record {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw ReadError.unavailable }
        return try readOwnedDescriptor(descriptor, name: url.lastPathComponent)
    }

    /// Consumes and always closes a descriptor opened relative to a verified
    /// metadata directory, avoiding path re-resolution during traversal.
    static func readOwnedDescriptor(_ descriptor: Int32, name: String) throws -> Record {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw ReadError.unavailable }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ReadError.notRegular }
        try Task.checkCancellation()

        var data = try handle.read(upToCount: readChunkBytes) ?? Data()
        // Names alone are insufficient: rclone can store genuine JSON metadata
        // for hidden remote files, even files named .DS_Store or ._anything.
        // Ignore only the actual Finder binary formats under their known names.
        if isFinderSidecar(name: name, prefix: data) {
            return .finderSidecar
        }
        guard before.st_size >= 0, before.st_size <= maximumMetadataBytes else { throw ReadError.tooLarge }
        while !data.isEmpty && data.count <= maximumMetadataBytes {
            try Task.checkCancellation()
            let remaining = maximumMetadataBytes + 1 - data.count
            let chunk = try handle.read(upToCount: min(readChunkBytes, remaining)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximumMetadataBytes else { throw ReadError.tooLarge }

        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw ReadError.unavailable }
        guard before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == Int(after.st_size) else { throw ReadError.changedDuringRead }
        do {
            return .metadata(dirty: try JSONDecoder().decode(Metadata.self, from: data).Dirty)
        } catch {
            throw ReadError.malformed
        }
    }

    static func isFinderSidecar(name: String, prefix: Data) -> Bool {
        if name == ".DS_Store" {
            // Finder DS_Store: version 1 followed by the Bud1 allocator magic.
            return prefix.starts(with: [0x00, 0x00, 0x00, 0x01, 0x42, 0x75, 0x64, 0x31])
        }
        if name.hasPrefix("._") {
            // AppleDouble magic and version 1 or 2. Other dotfiles are NOT skipped.
            let header = Array(prefix.prefix(8))
            guard header.count == 8, Array(header.prefix(4)) == [0x00, 0x05, 0x16, 0x07] else { return false }
            return Array(header.suffix(4)) == [0x00, 0x02, 0x00, 0x00]
                || Array(header.suffix(4)) == [0x00, 0x01, 0x00, 0x00]
        }
        return false
    }

    private struct Metadata: Decodable { let Dirty: Bool }
}
