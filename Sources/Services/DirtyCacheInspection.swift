import Darwin
import Foundation

struct DirtyCacheObservation: Equatable, Sendable {
    let complete: Bool
    let dirtyFiles: Int
    let detail: String
}

/// Read-only exit evidence from rclone's private metadata, not a public cache-purge
/// API. Unknown records, escapes or exceeded budgets fail closed. Never enumerate
/// the mounted cloud tree or modify cached content to make an exit check succeed.
enum DirtyCacheInspection {
    static func inspect(metadataPath: String?, cacheRoot: URL) async -> DirtyCacheObservation {
        guard let metadataPath else { return unknown("rclone did not identify its cache metadata directory.") }
        let worker = Task.detached(priority: .utility) { scan(metadataPath: metadataPath, cacheRoot: cacheRoot) }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
    }

    /// Used only after the helper has detached. Absence is safe only when there
    /// is no VFS data either; unreadable/malformed metadata never authorizes a root change.
    static func inspectUnmountedCache(cacheRoot: URL) async -> DirtyCacheObservation {
        let worker = Task.detached(priority: .utility) { () -> DirtyCacheObservation in
            var rootInfo = stat()
            guard lstat(cacheRoot.path, &rootInfo) == 0,
                  rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                return unknown("The previous cache could not be inspected.")
            }
            let metadata = cacheRoot.appendingPathComponent("vfsMeta", isDirectory: true)
            var info = stat()
            if lstat(metadata.path, &info) == 0 {
                return scan(metadataPath: metadata.path, cacheRoot: cacheRoot)
            }
            guard errno == ENOENT else { return unknown("The previous cache metadata is unavailable.") }
            let data = cacheRoot.appendingPathComponent("vfs", isDirectory: true)
            guard lstat(data.path, &info) != 0, errno == ENOENT, !Task.isCancelled else {
                return unknown("Cached files exist without readable write-status metadata.")
            }
            return DirtyCacheObservation(complete: true, dirtyFiles: 0, detail: "No previous VFS cache was found.")
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func scan(metadataPath: String, cacheRoot: URL) -> DirtyCacheObservation {
        guard !metadataPath.contains("\0"), !cacheRoot.path.contains("\0"), cacheRoot.isFileURL else { return unknown("Invalid private cache path.") }
        let root = cacheRoot.resolvingSymlinksInPath().standardizedFileURL
        let lexicalRoot = cacheRoot.standardizedFileURL
        let metadata = URL(fileURLWithPath: metadataPath, isDirectory: true).standardizedFileURL
        let relative: String
        if metadata.path.hasPrefix(lexicalRoot.path + "/") {
            relative = String(metadata.path.dropFirst(lexicalRoot.path.count + 1))
        } else if metadata.path.hasPrefix(root.path + "/") {
            relative = String(metadata.path.dropFirst(root.path.count + 1))
        } else { return unknown("Metadata was outside the private cache.") }
        let canonical = root.appendingPathComponent(relative, isDirectory: true).standardizedFileURL
        guard metadata.resolvingSymlinksInPath().standardizedFileURL == canonical else {
            return unknown("The cache metadata path traversed a symbolic link.")
        }
        let descriptor = openDirectory(root: root, relative: relative)
        guard descriptor >= 0 else { return unknown("Cache metadata could not be opened without following links.") }
        guard let initial = fdopendir(descriptor) else {
            close(descriptor)
            return unknown("Cache metadata could not be enumerated.")
        }
        // Descriptor-relative POSIX traversal includes .DS_Store when it contains
        // genuine rclone metadata; Foundation may implicitly hide it. No directory
        // of paths is accumulated, and no symlink is followed between check/open.
        var directories: [UnsafeMutablePointer<DIR>] = [initial]
        defer { for stream in directories { closedir(stream) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var incomplete = false
        var dirty = 0
        var entries = 0
        while let stream = directories.last {
            if Task.isCancelled || ContinuousClock.now >= deadline || entries >= 50_000 {
                incomplete = true
                break
            }
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { incomplete = true }
                directories.removeLast()
                closedir(stream)
                continue
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { incomplete = true; continue }
            if name == "." || name == ".." { continue }
            entries += 1
            let parent = dirfd(stream)
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { incomplete = true; continue }
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                guard directories.count < 128 else { incomplete = true; continue }
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { incomplete = true; continue }
                guard let next = fdopendir(child) else { close(child); incomplete = true; continue }
                directories.append(next)
            case mode_t(S_IFREG):
                let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard file >= 0 else { incomplete = true; continue }
                do {
                    let record = try autoreleasepool {
                        try CacheMetadataReader.readOwnedDescriptor(file, name: name)
                    }
                    if case .metadata(dirty: true) = record { dirty += 1 }
                } catch {
                    incomplete = true
                }
            default:
                // A link/device/socket is not trustworthy clean-cache evidence.
                incomplete = true
            }
        }
        if Task.isCancelled || !FileManager.default.fileExists(atPath: canonical.path) { incomplete = true }
        return DirtyCacheObservation(complete: !incomplete, dirtyFiles: dirty,
            detail: incomplete ? "Some cache metadata was unavailable; writer safety is unknown."
                : (dirty > 0 ? "Local modified files remain in the cache, including writes not yet queued." : "No dirty cache metadata was observed."))
    }

    private static func openDirectory(root: URL, relative: String) -> Int32 {
        var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for part in relative.split(separator: "/", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part != ".", part != "..", !Task.isCancelled else { close(descriptor); return -1 }
            let next = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return -1 }
            descriptor = next
        }
        return descriptor
    }

    private static func unknown(_ detail: String) -> DirtyCacheObservation {
        DirtyCacheObservation(complete: false, dirtyFiles: 0, detail: detail)
    }
}
