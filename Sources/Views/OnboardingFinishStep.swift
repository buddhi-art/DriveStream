import SwiftUI

struct OnboardingFinishStep: View {
    @ObservedObject var controller: MountController
    @ObservedObject var dependencies: DependencyManager
    @Binding var autoMount: Bool

    let connectedAccountSubtitle: String
    let volumeName: String
    let mountLocation: MountLocationPreference
    let mountBackend: MountBackendPreference
    let cacheMaxSize: String
    let enableEncryption: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Ready to mount")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("One more step. DriveStream will prepare the volume and index its directory tree in the background.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            OnboardingCard {
                VStack(spacing: 10) {
                    OnboardingSummaryRow(title: "Account", value: connectedAccountSubtitle)
                    Divider().opacity(0.5)
                    OnboardingSummaryRow(title: "Finder volume", value: sanitizedVolumeName)
                    Divider().opacity(0.5)
                    OnboardingSummaryRow(title: "Mount point", value: previewMountPath)
                    Divider().opacity(0.5)
                    OnboardingSummaryRow(title: "Backend", value: backendSummary)
                    Divider().opacity(0.5)
                    OnboardingSummaryRow(title: "Local cache", value: "\(normalizedCacheSize) maximum")
                    Divider().opacity(0.5)
                    OnboardingSummaryRow(
                        title: "Encryption",
                        value: enableEncryption ? "Enabled (rclone crypt)" : "Disabled"
                    )
                }
            }

            OnboardingCard {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $autoMount) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mount automatically when DriveStream launches")
                                .font(.system(size: 11.5, weight: .medium))
                            Text("You can change this any time in Settings.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    HStack(spacing: 8) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .foregroundStyle(.orange)
                        Text("After mounting, DriveStream runs a recursive vfs/refresh. The menu bar will show “Indexing directory tree in RAM...” until every directory is warm.")
                            .font(.system(size: 9.8))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var sanitizedVolumeName: String {
        var mutable = controller.config
        mutable.volumeName = volumeName
        return mutable.sanitizedVolumeName
    }

    private var previewMountPath: String {
        var mutable = controller.config
        mutable.volumeName = volumeName
        mutable.mountLocation = mountLocation
        return mutable.resolvedMountPath(volumesWritable: FileManager.default.isWritableFile(atPath: "/Volumes"))
    }

    private var normalizedCacheSize: String {
        SizeParser.canonicalString(from: cacheMaxSize) ?? cacheMaxSize
    }

    private var backendSummary: String {
        switch mountBackend {
        case .auto:
            if dependencies.fuseAvailability.macFUSEInstalled { return "Automatic · macFUSE / FSKit" }
            if dependencies.fuseAvailability.fuseTInstalled { return "Automatic · FUSE-T" }
            return "Automatic · Built-in NFS"
        case .macFUSE:
            return "macFUSE / FSKit"
        case .nfs:
            return "Built-in NFS"
        }
    }
}
