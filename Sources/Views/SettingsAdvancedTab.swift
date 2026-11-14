import SwiftUI

struct SettingsAdvancedTab: View {
    @Binding var draft: StreamConfig
    @ObservedObject var controller: MountController
    @ObservedObject var dependencies: DependencyManager

    let onOpenLogs: () -> Void
    let onOpenConfigFolder: () -> Void
    let onRefreshFinderServices: () -> Void
    let onRestartFinder: () -> Void
    let onShowSetupAssistant: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsSection(
                    title: "Mount backend",
                    subtitle: "Automatic is recommended."
                ) {
                    ForEach(MountBackendPreference.allCases) { preference in
                        Button {
                            draft.mountBackend = preference
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: draft.mountBackend == preference ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(draft.mountBackend == preference ? Color.accentColor : Color.secondary)
                                    .font(.system(size: 13))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preference.displayName)
                                        .font(.system(size: 11.5, weight: .medium))
                                    Text(preference.summary)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }

                SettingsSection(
                    title: "Diagnostics",
                    subtitle: "Useful paths and build information."
                ) {
                    AccountInfoRow(title: "Volume", value: controller.volumeName, detail: previewMountPath)
                    AccountInfoRow(title: "Backend", value: controller.backendDescription, detail: dependencies.fuseAvailability.summary)
                    AccountInfoRow(title: "rclone", value: dependencies.installation?.displayVersion ?? "Not installed", detail: dependencies.paths.rcloneBinary.path)
                    AccountInfoRow(title: "Config", value: "Private rclone config (0600)", detail: dependencies.paths.configFile.path)
                    AccountInfoRow(title: "Cache", value: ByteFormat.bytes(controller.telemetry.cacheBytes), detail: dependencies.paths.cacheDirectory.path)
                    AccountInfoRow(title: "Control endpoint", value: controller.rcClient.baseURL?.absoluteString ?? "Not mounted", detail: "Kernel-assigned loopback port; authenticated and verified against the mount process ID.")
                    AccountInfoRow(title: "Logs", value: controller.currentLogURL?.lastPathComponent ?? "No log yet", detail: dependencies.paths.logsDirectory.path)
                    HStack(spacing: 8) {
                        Button("Open Logs") { onOpenLogs() }
                        Button("Open Config Folder") { onOpenConfigFolder() }
                        Button("Refresh Finder Services") { onRefreshFinderServices() }
                        Button("Restart Finder") { onRestartFinder() }
                        Spacer()
                    }
                    .controlSize(.small)
                }

                SettingsSection(
                    title: "Security",
                    subtitle: "Local-only control plane."
                ) {
                    Label("rclone RC is bound to 127.0.0.1 and protected by a random per-mount password.", systemImage: "lock.shield.fill")
                        .font(.system(size: 10.5))
                    Label("OAuth tokens live only in DriveStream's private rclone.conf (0600).", systemImage: "key.fill")
                        .font(.system(size: 10.5))
                    Label("Crypt passwords are stored in the login Keychain; config copies are reversibly obscured and kept private.", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 10.5))
                    Label("DriveStream collects no analytics and has no remote telemetry.", systemImage: "eye.slash.fill")
                        .font(.system(size: 10.5))
                    Divider().opacity(0.5)
                    HStack {
                        Text("App version \(appVersion)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Open Setup Assistant") {
                            onShowSetupAssistant()
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(16)
        }
    }

    private var previewMountPath: String {
        draft.resolvedMountPath(volumesWritable: FileManager.default.isWritableFile(atPath: "/Volumes"))
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
