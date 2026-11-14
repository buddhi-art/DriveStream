import Darwin
import Foundation

/// Operations on app-created staging files. No remove-before-replace fallback:
/// failure must leave a previously installed binary/config/download intact.
enum ServiceFileSafety {
    static func temporaryDirectory(prefix: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let directory = parent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try requireChild(directory, of: parent)
        guard mkdir(directory.path, 0o700) == 0 else { throw posixError() }
        return directory
    }

    static func removeTemporaryDirectory(_ directory: URL, prefix: String) {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard directory.lastPathComponent.hasPrefix(prefix),
              (try? requireChild(directory, of: parent)) != nil,
              directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static func requireChild(_ child: URL, of parent: URL) throws {
        guard child.isFileURL, parent.isFileURL,
              child.standardizedFileURL.deletingLastPathComponent() == parent.standardizedFileURL,
              !child.lastPathComponent.isEmpty, child.lastPathComponent != ".", child.lastPathComponent != ".." else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    static func createPrivateFile(_ url: URL, data: Data = Data()) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target = parent.appendingPathComponent(destination.lastPathComponent)
        let staging = parent.appendingPathComponent(".DriveStream-write-" + UUID().uuidString)
        try requireChild(target, of: parent)
        defer { removeStaging(staging, parent: parent, prefix: ".DriveStream-write-") }
        try createPrivateFile(staging, data: data)
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        try handle.synchronize()
        try atomicReplace(staging, destination: target)
    }

    static func atomicReplace(_ staging: URL, destination: URL) throws {
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        try requireChild(staging, of: parent)
        try requireChild(destination, of: parent)
        guard staging.resolvingSymlinksInPath().standardizedFileURL == staging.standardizedFileURL,
              destination.resolvingSymlinksInPath().standardizedFileURL == destination.standardizedFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard rename(staging.path, destination.path) == 0 else { throw posixError() }
    }

    static func removeStaging(_ staging: URL, parent: URL, prefix: String) {
        guard staging.lastPathComponent.hasPrefix(prefix),
              (try? requireChild(staging, of: parent)) != nil,
              staging.resolvingSymlinksInPath().standardizedFileURL == staging.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: staging)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
