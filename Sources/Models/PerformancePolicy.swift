import Foundation

enum PerformanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case responsive
    case memorySaver

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic (recommended)"
        case .responsive: return "Maximum responsiveness"
        case .memorySaver: return "Lower memory use"
        }
    }
}

/// These policies budget Swift cache warming and rclone upload buffers separately.
/// They do not claim control over every open VFS file or the OS page cache.
struct PerformancePolicy: Equatable, Sendable {
    let mode: PerformanceMode
    let pinConcurrency: Int
    let transfers: Int
    let bufferSize: String
    let driveChunkSize: String
    let lowerMemoryProfile: Bool

    static func resolve(mode: PerformanceMode, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                        pinOverride: Int = 0) -> PerformancePolicy {
        let smallMac = physicalMemory < 16 * 1024 * 1024 * 1024
        let conserve = mode == .memorySaver || (mode == .automatic && smallMac)
        let automaticPins = conserve ? 2 : 4
        let pins = pinOverride > 0 ? min(max(pinOverride, 1), 4) : automaticPins
        return PerformancePolicy(mode: mode, pinConcurrency: pins, transfers: conserve ? 4 : 8,
                                 bufferSize: conserve ? "16M" : "32M",
                                 driveChunkSize: conserve ? "16M" : "64M", lowerMemoryProfile: conserve)
    }

    var explanation: String {
        lowerMemoryProfile
            ? "Smaller per-file/upload buffers leave more memory for Finder and editors. Cache warming uses bounded parallel reads."
            : "Larger buffers favor responsiveness when memory is available. Swift cache warming still caps concurrent file reads."
    }
}
