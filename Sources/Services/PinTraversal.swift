import Darwin
import Foundation

struct PinFileWork: Sendable {
    let descriptor: Int32
    let path: String
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
}

/// This cursor is confined to PinCoordinator's lock, accessed only by dedicated I/O
/// queues. Memory is O(selected roots + directory depth), never O(files in the tree).
/// All child opens are descriptor-relative and no-follow, including intermediate
/// components. No URL enumeration or subsequent path-based FileHandle reopen.
struct PinTraversal: Sendable {
    private struct Selection: Sendable {
        let path: String
        var failed = false
    }
    private struct Directory: Sendable {
        // Opaque POSIX handles are represented like file descriptors. The cursor
        // is owned/mutated only inside the coordinator's native allocated lock.
        let handle: UInt
        let path: String
        var stream: UnsafeMutablePointer<DIR> { UnsafeMutablePointer<DIR>(bitPattern: handle)! }
    }

    private let cancellation: PinCancellation
    private let hooks: PinIOHooks
    private var mountDescriptor: Int32 = -1
    private var selections: [Selection] = []
    private var pendingRoots: [String] = []
    private var nextRoot = 0
    private var directories: [Directory] = []
    private(set) var failedFiles = 0

    init(roots: [URL], mountPath: String, relativePaths: [String],
         cancellation: PinCancellation, hooks: PinIOHooks) {
        self.cancellation = cancellation
        self.hooks = hooks
        guard !roots.isEmpty else {
            failedFiles = relativePaths.count
            return
        }
        guard !mountPath.contains("\0") else {
            failedFiles = max(roots.count, relativePaths.count)
            return
        }
        let lexicalMount = URL(fileURLWithPath: mountPath).standardizedFileURL.path
        let canonicalMount = URL(fileURLWithPath: mountPath).resolvingSymlinksInPath().standardizedFileURL.path
        guard !cancellation.isCancelled else { return }
        mountDescriptor = Darwin.open(canonicalMount, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard mountDescriptor >= 0 else {
            failedFiles = max(roots.count, relativePaths.count)
            return
        }
        hooks.descriptorActivity?(1)

        var seen = Set<String>()
        for (index, root) in roots.enumerated() {
            if cancellation.isCancelled { break }
            guard index < relativePaths.count, root.isFileURL,
                  !root.path.contains("\0"), !root.pathComponents.contains("..") else {
                failedFiles += 1
                continue
            }
            let path = root.standardizedFileURL.path
            let relative: String
            if path.hasPrefix(canonicalMount + "/") {
                relative = String(path.dropFirst(canonicalMount.count + 1))
            } else if path.hasPrefix(lexicalMount + "/") {
                relative = String(path.dropFirst(lexicalMount.count + 1))
            } else {
                failedFiles += 1
                continue
            }
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !relative.isEmpty, relative == relativePaths[index],
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !components.contains(where: { Self.isIgnored(String($0)) }) else {
                failedFiles += 1
                continue
            }
            guard seen.insert(relative).inserted else { continue }
            let descriptor = openRelative(relative)
            var info = stat()
            guard descriptor >= 0 else {
                failedFiles += 1
                continue
            }
            let valid = fstat(descriptor, &info) == 0 &&
                ((info.st_mode & S_IFMT) == S_IFREG || (info.st_mode & S_IFMT) == S_IFDIR)
            closeDescriptor(descriptor)
            guard valid else {
                failedFiles += 1
                continue
            }
            selections.append(Selection(path: relative))
        }
        if relativePaths.count > roots.count { failedFiles += relativePaths.count - roots.count }
        let ordered = selections.map(\.path).sorted()
        for path in ordered {
            // Lexically adjacent ancestor first; retained paths are user selections,
            // not an enumerated-file set. A nested selection still gets its own marker.
            if !pendingRoots.contains(where: { Self.contains($0, path) }) {
                pendingRoots.append(path)
            }
        }
    }

    mutating func close() {
        for directory in directories { closeDirectory(directory) }
        directories.removeAll()
        if mountDescriptor >= 0 { closeDescriptor(mountDescriptor) }
        mountDescriptor = -1
    }

    var pinnedPaths: Set<String> {
        Set(selections.filter { !$0.failed }.map(\.path))
    }

    mutating func readFailed(path: String) { failure(path: path, subtree: false) }

    mutating func next() -> PinFileWork? {
        while !cancellation.isCancelled {
            if let directory = directories.last {
                errno = 0
                guard let entry = readdir(directory.stream) else {
                    let error = errno
                    directories.removeLast()
                    closeDirectory(directory)
                    if error != 0 { failure(path: directory.path, subtree: true) }
                    continue
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." || Self.isIgnored(name) { continue }
                let path = directory.path + "/" + name
                var info = stat()
                let parent = dirfd(directory.stream)
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    failure(path: path, subtree: true)
                    continue
                }
                let kind = info.st_mode & S_IFMT
                if kind == S_IFLNK { continue } // Deliberately ineligible, never traversed.
                if kind == S_IFDIR {
                    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if fd < 0 { failure(path: path, subtree: true); continue }
                    hooks.descriptorActivity?(1)
                    pushDirectory(fd, path: path)
                } else if kind == S_IFREG {
                    let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                    if fd < 0 { failure(path: path, subtree: false); continue }
                    hooks.descriptorActivity?(1)
                    if let file = fileWork(fd, path: path) { return file }
                }
            } else {
                guard nextRoot < pendingRoots.count else { return nil }
                let path = pendingRoots[nextRoot]
                nextRoot += 1
                let fd = openRelative(path)
                if fd < 0 { failure(path: path, subtree: true); continue }
                var info = stat()
                guard fstat(fd, &info) == 0 else {
                    closeDescriptor(fd)
                    failure(path: path, subtree: true)
                    continue
                }
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    pushDirectory(fd, path: path)
                } else if let file = fileWork(fd, path: path) {
                    return file
                }
            }
        }
        return nil
    }

    private mutating func pushDirectory(_ fd: Int32, path: String) {
        if hooks.failEnumeration?(path) == true {
            closeDescriptor(fd)
            failure(path: path, subtree: true)
            return
        }
        guard let stream = fdopendir(fd) else {
            closeDescriptor(fd)
            failure(path: path, subtree: true)
            return
        }
        directories.append(Directory(handle: UInt(bitPattern: stream), path: path))
    }

    private mutating func fileWork(_ fd: Int32, path: String) -> PinFileWork? {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            closeDescriptor(fd)
            failure(path: path, subtree: true)
            return nil
        }
        return PinFileWork(descriptor: fd, path: path, size: info.st_size,
                           modifiedSeconds: info.st_mtimespec.tv_sec,
                           modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }

    private func openRelative(_ path: String) -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        var parent = mountDescriptor
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC |
                (index == parts.count - 1 ? O_NONBLOCK : O_DIRECTORY)
            let fd = openat(parent, part, flags)
            if parent != mountDescriptor { closeDescriptor(parent) }
            guard fd >= 0 else { return -1 }
            hooks.descriptorActivity?(1)
            parent = fd
        }
        return parent == mountDescriptor ? -1 : parent
    }

    private mutating func failure(path: String, subtree: Bool) {
        failedFiles += 1
        for index in selections.indices {
            if Self.contains(selections[index].path, path) ||
                (subtree && Self.contains(path, selections[index].path)) {
                selections[index].failed = true
            }
        }
    }

    private func closeDescriptor(_ fd: Int32) {
        Darwin.close(fd)
        hooks.descriptorActivity?(-1)
    }

    private func closeDirectory(_ directory: Directory) {
        closedir(directory.stream)
        hooks.descriptorActivity?(-1)
    }

    private static func contains(_ ancestor: String, _ path: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor + "/")
    }

    private static func isIgnored(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store" || name == ".metadata_never_index"
            || name == ".VolumeIcon.icns"
    }
}
