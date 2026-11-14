import Foundation
import os

// Official static rclone builds, native on Apple Silicon (including M1) and Intel.
enum RcloneDownloads {
    private static let baseURL = URL(string: "https://downloads.rclone.org")!
    static let versionURL = baseURL.appendingPathComponent("version.txt")

    /// Pin all archive and checksum selection to the same validated stable release.
    /// A moving `rclone-current` alias can change after version.txt is fetched.
    struct Release: Sendable {
        let version: String
        let architecture: String

        var archiveName: String { "rclone-\(version)-osx-\(architecture).zip" }
        var downloadURL: URL { directoryURL.appendingPathComponent(archiveName) }
        var checksumURL: URL { directoryURL.appendingPathComponent("SHA256SUMS") }

        private var directoryURL: URL {
            RcloneDownloads.baseURL.appendingPathComponent(version, isDirectory: true)
        }

        init(versionText: String, architecture: String) throws {
            guard architecture == "arm64" || architecture == "amd64" else {
                throw DependencyError.unsupportedArchitecture(architecture)
            }
            let text = versionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let expression = try? NSRegularExpression(pattern: #"\Arclone (v[0-9]+\.[0-9]+\.[0-9]+)\z"#),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else {
                throw DependencyError.verificationFailed("Unrecognized official release version.")
            }
            self.version = String(text[range])
            self.architecture = architecture
        }
    }
}

enum FileDownloadError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case emptyDownload
    case fileOperation(String)
    case alreadyUsed
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an invalid response."
        case .httpStatus(let status): return "The download failed with HTTP status \(status)."
        case .emptyDownload: return "The downloaded file was empty."
        case .fileOperation: return "Could not save the downloaded file."
        case .alreadyUsed: return "A downloader may only be used once."
        case .tooLarge: return "The download exceeded its size limit."
        }
    }
}

/// All mutable state (including session/task ownership) lives inside one allocated
/// lock; the class itself has only immutable Sendable properties. Continuations and
/// callbacks are invoked outside the lock. Each instance is one-shot, and cancellation
/// resumes immediately without waiting for delegates.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State: Sendable {
        var started = false
        var completed = false
        var cancelled = false
        var continuation: CheckedContinuation<URL, any Error>?
        var destination: URL?
        var staging: URL?
        var progress: (@Sendable (Double) -> Void)?
        var session: URLSession?
        var task: URLSessionDownloadTask?
        var copyError: (any Error)?
        var copied = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let maximumBytes: Int64

    init(maximumBytes: Int64 = 512 * 1024 * 1024) {
        self.maximumBytes = maximumBytes
        super.init()
    }

    func download(from url: URL, to destination: URL,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 1_800
                configuration.httpAdditionalHeaders = ["User-Agent": "DriveStream/1.1.0 (macOS)"]
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                let setupError: (any Error)? = state.withLock { state in
                    guard !state.started else { return FileDownloadError.alreadyUsed }
                    state.started = true
                    guard !state.cancelled else { state.completed = true; return CancellationError() }
                    do {
                        let fileManager = FileManager.default
                        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                        let target = parent.appendingPathComponent(destination.lastPathComponent)
                        try ServiceFileSafety.requireChild(target, of: parent)
                        let staging = parent.appendingPathComponent(".DriveStream-download-" + UUID().uuidString)
                        try ServiceFileSafety.createPrivateFile(staging)
                        state.destination = target
                        state.staging = staging
                        state.continuation = continuation
                        state.progress = progress
                        state.session = session
                        state.task = task
                        return nil
                    } catch {
                        state.completed = true
                        return FileDownloadError.fileOperation(error.localizedDescription)
                    }
                }
                if let setupError {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: setupError)
                } else {
                    // Cancellation may win before resume; a cancelled task never restarts.
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        let snapshot = state.withLock { state -> State? in
            state.cancelled = true
            guard !state.completed else { return nil }
            state.completed = true
            let snapshot = state
            state.continuation = nil
            state.progress = nil
            state.session = nil
            state.task = nil
            return snapshot
        }
        guard let snapshot else { return }
        snapshot.task?.cancel()
        snapshot.session?.invalidateAndCancel()
        cleanup(snapshot)
        snapshot.continuation?.resume(throwing: CancellationError())
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard state.withLock({ !$0.completed && $0.session === session && $0.task === downloadTask }) else { return }
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            finish(error: FileDownloadError.tooLarge)
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let handler = state.withLock { $0.completed ? nil : $0.progress }
        handler?(min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard state.withLock({ !$0.completed && $0.session === session && $0.task === downloadTask }) else { return }
        // Validate HTTP before touching the destination. Only a private staging file
        // is written here; commit happens after didComplete reports success.
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(error: FileDownloadError.invalidResponse); return
        }
        guard (200...299).contains(response.statusCode) else {
            finish(error: FileDownloadError.httpStatus(response.statusCode)); return
        }
        guard let staging = state.withLock({ $0.completed ? nil : $0.staging }) else { return }
        do {
            let source = try FileHandle(forReadingFrom: location)
            defer { try? source.close() }
            let target = try FileHandle(forWritingTo: staging)
            defer { try? target.close() }
            var count: Int64 = 0
            while true {
                guard !state.withLock({ $0.completed }) else { return }
                let chunk = try source.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                count += Int64(chunk.count)
                guard count <= maximumBytes else { throw FileDownloadError.tooLarge }
                try target.write(contentsOf: chunk)
            }
            guard count > 0 else { throw FileDownloadError.emptyDownload }
            try target.synchronize()
            state.withLock { if !$0.completed { $0.copied = true } }
        } catch {
            state.withLock { if !$0.completed { $0.copyError = error } }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard state.withLock({ !$0.completed && $0.session === session && $0.task === task }) else { return }
        if let error { finish(error: error); return }
        guard let response = task.response as? HTTPURLResponse else {
            finish(error: FileDownloadError.invalidResponse); return
        }
        guard (200...299).contains(response.statusCode) else {
            finish(error: FileDownloadError.httpStatus(response.statusCode)); return
        }
        finish(error: nil)
    }

    private func finish(error: (any Error)?) {
        let result = state.withLock { state -> (State, Result<URL, any Error>)? in
            guard !state.completed else { return nil }
            state.completed = true
            let result: Result<URL, any Error>
            if let failure = error ?? state.copyError {
                result = .failure(failure)
            } else if state.copied, let staging = state.staging, let destination = state.destination {
                do {
                    try ServiceFileSafety.atomicReplace(staging, destination: destination)
                    result = .success(destination)
                } catch { result = .failure(FileDownloadError.fileOperation(error.localizedDescription)) }
            } else { result = .failure(FileDownloadError.emptyDownload) }
            let snapshot = state
            state.continuation = nil
            state.progress = nil
            state.session = nil
            state.task = nil
            return (snapshot, result)
        }
        guard let (snapshot, result) = result else { return }
        snapshot.session?.invalidateAndCancel()
        cleanup(snapshot)
        snapshot.continuation?.resume(with: result)
    }

    private func cleanup(_ snapshot: State) {
        guard let staging = snapshot.staging, let destination = snapshot.destination else { return }
        ServiceFileSafety.removeStaging(staging, parent: destination.deletingLastPathComponent(), prefix: ".DriveStream-download-")
    }
}
