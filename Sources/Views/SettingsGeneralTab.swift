import SwiftUI

struct SettingsGeneralTab: View {
    @Binding var draft: StreamConfig
    @ObservedObject var loginItems: LoginItemManager

    let onCopyMountPath: () -> Void
    let onSetLoginEnabled: (Bool) -> Void
    let onOpenLoginApproval: () -> Void
    let onShowSidebarHelp: () -> Void
    let onRevealMountFolder: () -> Void
    let onApplyFinderPreferences: () -> Void
    let onRestartFinder: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsSection(
                    title: "Volume",
                    subtitle: "How Google Drive appears in Finder."
                ) {
                    SettingsRow("Name in Finder", description: "Shown in the Finder sidebar and Get Info.") {
                        TextField("Google Drive", text: $draft.volumeName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    Divider().opacity(0.5)
                    SettingsRow("Mount location", description: draft.mountLocation.summary) {
                        Picker("", selection: $draft.mountLocation) {
                            ForEach(MountLocationPreference.allCases) { location in
                                Text(location.displayName).tag(location)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    Divider().opacity(0.5)
                    SettingsRow("Custom mount path", description: "Optional. Leave empty for the automatic location.") {
                        TextField("Automatic", text: $draft.customMountPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    Divider().opacity(0.5)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Resolved path")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(previewMountPath)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            onCopyMountPath()
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy the resolved mount path")
                    }
                }

                SettingsSection(
                    title: "Startup & Finder",
                    subtitle: "Finder-friendly defaults that keep cloud browsing responsive."
                ) {
                    SettingsRow("Launch at login", description: "Keep your mount available after signing in to this Mac.") {
                        Toggle("", isOn: Binding(get: { loginItems.enabled || loginItems.requiresApproval }, set: { onSetLoginEnabled($0) }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                    if loginItems.requiresApproval {
                        Button("Approve in Login Items") { onOpenLoginApproval() }.controlSize(.small)
                    }
                    if let issue = loginItems.errorMessage {
                        Text(issue).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider().opacity(0.5)
                    SettingsRow("Restore after wake", description: "Keep healthy mounts attached and recover a stopped session after wake when possible.") {
                        Toggle("", isOn: $draft.recoverMountAfterWake).labelsHidden().toggleStyle(.switch)
                    }
                    Divider().opacity(0.5)
                    SettingsRow("Mount automatically", description: "Mount when DriveStream launches.") {
                        Toggle("", isOn: $draft.autoMountOnLaunch)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    Divider().opacity(0.5)
                    SettingsRow(
                        "Suppress Spotlight",
                        description: "Attempts to suppress Spotlight with a root marker; disabling this does not remove an existing marker."
                    ) {
                        Toggle("", isOn: $draft.suppressSpotlightIndexing)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    Divider().opacity(0.5)
                    SettingsRow(
                        "Show drive on Desktop",
                        description: "Enables Finder's Desktop icons for mounted drives and servers."
                    ) {
                        Toggle("", isOn: $draft.showDriveOnDesktop)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    Divider().opacity(0.5)
                    HStack(spacing: 8) {
                        Button("Keep in Finder") { onShowSidebarHelp() }
                        Button("Reveal Mount Folder") {
                            onRevealMountFolder()
                        }
                        Button("Apply Finder Preferences") {
                            onApplyFinderPreferences()
                        }
                        Button("Restart Finder") {
                            onRestartFinder()
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                    Text("Finder controls Locations for attached volumes. Use Keep in Finder for a persistent Favorites shortcut while detached. Desktop preferences affect other drives too.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private var previewMountPath: String {
        draft.resolvedMountPath(volumesWritable: FileManager.default.isWritableFile(atPath: "/Volumes"))
    }
}
