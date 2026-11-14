import SwiftUI

struct OnboardingWelcomeStep: View {
    @ObservedObject var dependencies: DependencyManager
    let onPrepareRclone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Mount 5 TB of Google Drive as a native Mac volume.")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text("DriveStream is a local-first Finder experience: RAM-indexed metadata, NVMe-speed staged writes, and byte-range streaming for 4K media.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            OnboardingCard {
                VStack(alignment: .leading, spacing: 11) {
                    FeatureRow(
                        symbol: "bolt.fill",
                        tint: .orange,
                        title: "RAM-cached directory tree",
                        detail: "A recursive vfs/refresh pre-warms every folder into memory. Finder listings are instant."
                    )
                    FeatureRow(
                        symbol: "externaldrive.fill",
                        tint: .blue,
                        title: "A real 5 TB volume",
                        detail: "Finder shows Google Drive capacity in Get Info and the status bar — not a network drive."
                    )
                    FeatureRow(
                        symbol: "arrow.up.arrow.down",
                        tint: .teal,
                        title: "NVMe-speed drag and drop",
                        detail: "Writes land in the local VFS cache in milliseconds, then upload in the background."
                    )
                    FeatureRow(
                        symbol: "film.fill",
                        tint: .purple,
                        title: "4K byte-range streaming",
                        detail: "Tuned 16–256 MB chunks and 64 MB read-ahead keep QuickTime and Resolve scrubbing smooth."
                    )
                    FeatureRow(
                        symbol: "lock.shield.fill",
                        tint: .green,
                        title: "Optional end-to-end encryption",
                        detail: "rclone crypt with Keychain-protected passwords. Google sees only ciphertext."
                    )
                }
            }

            dependencyCard
        }
    }

    private var dependencyCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    DependencyIcon(phase: dependencies.phase)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dependencyTitle)
                            .font(.system(size: 12, weight: .semibold))
                        Text(dependencyDetail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if dependencies.isRcloneReady {
                        Text(dependencies.installation?.architecture.uppercased() ?? "ARM64")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.12), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }

                switch dependencies.phase {
                case .downloading(let progress):
                    ProgressView(value: progress)
                        .tint(.blue)
                case .checking, .extracting:
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8, anchor: .leading)
                case .failed:
                    HStack(spacing: 8) {
                        Button("Try Again") {
                            onPrepareRclone()
                        }
                        .controlSize(.small)
                        if let path = dependencies.installation?.path {
                            Text(path)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                case .idle:
                    Button("Prepare rclone") {
                        onPrepareRclone()
                    }
                    .controlSize(.small)
                case .ready:
                    EmptyView()
                }

                Text("DriveStream downloads the official static rclone build (never Homebrew) into ~/Library/Application Support/DriveStream/bin. No Terminal or Xcode required.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dependencyTitle: String {
        switch dependencies.phase {
        case .idle: return "Official rclone is not installed yet"
        case .checking: return "Checking rclone…"
        case .downloading(_): return "Downloading official rclone"
        case .extracting: return "Installing the static binary"
        case .ready: return "rclone is ready"
        case .failed: return "rclone setup needs attention"
        }
    }

    private var dependencyDetail: String {
        switch dependencies.phase {
        case .idle:
            return "DriveStream bundles no binary and uses no Homebrew. The official static rclone build is downloaded into Application Support."
        case .checking:
            return "Verifying the existing binary and mount support…"
        case .downloading(let progress):
            return "\(Int(progress * 100))% from downloads.rclone.org"
        case .extracting:
            return "Verifying mount/VFS support and applying executable permissions…"
        case .ready:
            return "\(dependencies.installation?.displayVersion ?? "rclone") · \(dependencies.installation?.architecture.uppercased() ?? "ARM64") · ready for mounting"
        case .failed(let message):
            return message
        }
    }
}
