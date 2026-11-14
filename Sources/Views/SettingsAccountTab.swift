import SwiftUI

struct SettingsAccountTab: View {
    @Binding var draft: StreamConfig
    @ObservedObject var controller: MountController
    @ObservedObject var dependencies: DependencyManager

    let isReconnecting: Bool
    let isInstallingMacFUSE: Bool
    let onReconnect: () -> Void
    let onRemoveAccount: () -> Void
    let onShowSetupAssistant: () -> Void
    let onInstallMacFUSE: () -> Void
    let onOpenMacFUSEWebsite: () -> Void
    let onRefreshFuseAvailability: () -> Void
    let onInstallRclone: () -> Void
    let onRevealRcloneBinary: () -> Void
    let onOpenLogs: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsSection(
                    title: "Google Drive",
                    subtitle: "DriveStream stores tokens in a private config file with 0600 permissions."
                ) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(controller.isGoogleConnected ? Color.green : Color.secondary)
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(controller.isGoogleConnected ? "Connected" : "Not connected")
                                .font(.system(size: 12, weight: .semibold))
                            Text(accountSubtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(isReconnecting || controller.isConnecting ? "Reconnecting…" : "Reconnect") {
                            onReconnect()
                        }
                        .controlSize(.small)
                        .disabled(isReconnecting || controller.isConnecting)
                        Button("Remove…", role: .destructive) {
                            onRemoveAccount()
                        }
                        .controlSize(.small)
                        .disabled(controller.isBusy)
                    }
                    Divider().opacity(0.5)
                    AccountInfoRow(
                        title: "OAuth client",
                        value: controller.config.usesCustomOAuth ? "Personal Google Cloud client" : "rclone default client",
                        detail: controller.config.usesCustomOAuth
                            ? (controller.config.clientID.isEmpty ? "Configured" : controller.config.clientID)
                            : "Shared client is being retired upstream; use a personal client for new setups."
                    )
                    Button("Change OAuth credentials in Setup Assistant") {
                        onShowSetupAssistant()
                    }
                    .controlSize(.small)
                    Text("A personal OAuth Client ID is strongly recommended for 4K video scrubbing and Finder thumbnail storms. Create a Desktop OAuth client in Google Cloud Console, enable the Drive API, and add yourself as a test user. Reconnecting while mounted unmounts the volume until the new token is verified, then remounts it automatically.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsDriveRootSection(draft: $draft, controller: controller)

                SettingsSection(
                    title: "Client-side encryption",
                    subtitle: "Optional rclone crypt layered over Google Drive."
                ) {
                    SettingsRow(
                        "Encryption",
                        description: controller.config.useEncryption
                            ? "All new reads and writes pass through the encrypted remote."
                            : "Off. Files are stored in Google Drive with their original names."
                    ) {
                        Label(
                            controller.config.useEncryption ? "Enabled" : "Disabled",
                            systemImage: controller.config.useEncryption ? "lock.fill" : "lock.open"
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(controller.config.useEncryption ? Color.green : Color.secondary)
                    }
                    if controller.config.useEncryption {
                        Label(
                            controller.hasStoredEncryptionPassword
                                ? "Passwords are present in the macOS Keychain."
                                : "No encryption password was found in the Keychain.",
                            systemImage: controller.hasStoredEncryptionPassword ? "key.fill" : "exclamationmark.triangle"
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(controller.hasStoredEncryptionPassword ? Color.secondary : Color.orange)
                    }
                    Button("Manage encryption in Setup Assistant") {
                        onShowSetupAssistant()
                    }
                    .controlSize(.small)
                    Text("Encryption keys are saved in the macOS Keychain. rclone’s config stores reversibly obscured passwords, so the 0600 config must also be kept private. Enabling crypt changes which files are visible; use it for new or already-encrypted data.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(
                    title: "Filesystem backend",
                    subtitle: "DriveStream prefers macFUSE and automatically falls back to NFS."
                ) {
                    SettingsRow("Driver", description: draft.mountBackend.summary) {
                        Picker("", selection: $draft.mountBackend) {
                            ForEach(MountBackendPreference.allCases) { preference in
                                Text(preference.displayName).tag(preference)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    AccountInfoRow(
                        title: "FUSE availability",
                        value: dependencies.fuseAvailability.summary,
                        detail: "Installed bundle detection is not a driver-mode guarantee. Actual FSKit/kernel mode and required approvals depend on the driver, macOS and rclone."
                    )
                    HStack(spacing: 8) {
                        Button {
                            onInstallMacFUSE()
                        } label: {
                            Label(
                                dependencies.fuseAvailability.macFUSEInstalled ? "Update macFUSE…" : "Install macFUSE…",
                                systemImage: "arrow.down.circle"
                            )
                        }
                        .controlSize(.small)
                        .disabled(isInstallingMacFUSE)
                        Button("macFUSE Website") {
                            onOpenMacFUSEWebsite()
                        }
                        .controlSize(.small)
                        Button("Refresh Detection") {
                            onRefreshFuseAvailability()
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                    if let progress = dependencies.macFUSEProgress {
                        ProgressView(value: progress)
                            .tint(.blue)
                        Text("Downloading and verifying the official macFUSE installer…")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Text("The optional installer opens the notarized DMG. macOS asks for administrator approval, and the macFUSE system extension may need to be allowed in System Settings › Privacy & Security.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(
                    title: "rclone",
                    subtitle: "DriveStream uses only the official precompiled static build."
                ) {
                    AccountInfoRow(
                        title: "Installed version",
                        value: dependencies.installation?.displayVersion ?? "Not installed",
                        detail: dependencyPhaseDescription
                    )
                    HStack(spacing: 8) {
                        Button(dependencies.isRcloneReady ? "Update rclone" : "Download rclone") {
                            onInstallRclone()
                        }
                        .controlSize(.small)
                        .disabled(dependencies.phase.isWorking || controller.hasMountSession || controller.isBusy)
                        Button("Reveal Binary") {
                            onRevealRcloneBinary()
                        }
                        .controlSize(.small)
                        Button("Open Logs") {
                            onOpenLogs()
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                    if controller.hasMountSession {
                        Text("Unmount the volume before updating rclone so the running helper is never replaced.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text("Homebrew's rclone formula is intentionally not used: macOS builds from that formula can omit mount support. DriveStream always downloads from downloads.rclone.org.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private var accountSubtitle: String {
        if let account = controller.accountLabel ?? controller.config.accountEmail.nonEmpty {
            return account
        }
        return controller.isGoogleConnected ? "Google Drive remote is configured." : "Connect in the Setup Assistant."
    }

    private var dependencyPhaseDescription: String {
        switch dependencies.phase {
        case .idle: return "Waiting to check the installation."
        case .checking: return "Verifying the official rclone binary…"
        case .downloading(let progress): return "Downloading from downloads.rclone.org… \(Int(progress * 100))%"
        case .extracting: return "Extracting and verifying the static binary…"
        case .ready: return "Official rclone is ready."
        case .failed(let error): return error
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
