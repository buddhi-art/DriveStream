import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var controller: MountController
    @ObservedObject private var dependencies: DependencyManager

    private let onClose: (() -> Void)?

    @State private var draft: StreamConfig
    @State private var selectedTab: SettingsTab = .general
    @State private var isApplying = false
    @State private var isReconnecting = false
    @State private var isInstallingMacFUSE = false
    @State private var showRemoveAccountConfirmation = false
    @State private var showRestartFinderConfirmation = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var presentedIssue: DriveStreamIssue?
    @StateObject private var loginItems = LoginItemManager()

    init(controller: MountController, onClose: (() -> Void)? = nil) {
        self._controller = ObservedObject(wrappedValue: controller)
        self._dependencies = ObservedObject(wrappedValue: controller.dependencyManager)
        self.onClose = onClose
        self._draft = State(initialValue: controller.config)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                SettingsGeneralTab(
                    draft: $draft, loginItems: loginItems,
                    onCopyMountPath: { controller.copyMountPathToPasteboard() },
                    onSetLoginEnabled: { loginItems.setEnabled($0) },
                    onOpenLoginApproval: { loginItems.openApprovalSettings() },
                    onShowSidebarHelp: { controller.showSidebarHelp() },
                    onRevealMountFolder: { controller.openVolumeRootInFinder() },
                    onApplyFinderPreferences: { controller.applyFinderIntegrationNow() },
                    onRestartFinder: { showRestartFinderConfirmation = true }
                )
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(SettingsTab.general)

                SettingsPerformanceTab(
                    draft: $draft, controller: controller,
                    onFreeUpSpace: { Task { await controller.freeUpSpaceNow() } }
                )
                    .tabItem { Label("Performance", systemImage: "speedometer") }
                    .tag(SettingsTab.performance)

                SettingsAccountTab(
                    draft: $draft, controller: controller, dependencies: dependencies,
                    isReconnecting: isReconnecting, isInstallingMacFUSE: isInstallingMacFUSE,
                    onReconnect: performReconnect,
                    onRemoveAccount: { showRemoveAccountConfirmation = true },
                    onShowSetupAssistant: { controller.presentSetupAssistant() },
                    onInstallMacFUSE: performMacFUSEInstall,
                    onOpenMacFUSEWebsite: { dependencies.openMacFUSEWebsite() },
                    onRefreshFuseAvailability: { dependencies.refreshFuseAvailability() },
                    onInstallRclone: performRcloneInstall,
                    onRevealRcloneBinary: { dependencies.revealRcloneBinaryInFinder() },
                    onOpenLogs: { controller.openLogs() }
                )
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
                    .tag(SettingsTab.account)

                SettingsAdvancedTab(
                    draft: $draft, controller: controller, dependencies: dependencies,
                    onOpenLogs: { controller.openLogs() },
                    onOpenConfigFolder: { controller.openConfigFolder() },
                    onRefreshFinderServices: { controller.updateFinderServices() },
                    onRestartFinder: { showRestartFinderConfirmation = true },
                    onShowSetupAssistant: { controller.presentSetupAssistant() }
                )
                    .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                    .tag(SettingsTab.advanced)
            }
            .padding(.top, 6)

            Divider()
            footer
        }
        .frame(width: 700, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            dependencies.refreshFuseAvailability()
            loginItems.refresh()
        }
        .onChange(of: controller.config) { _, newValue in
            guard !isApplying else { return }
            draft = newValue
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .sheet(item: $presentedIssue) { issue in
            VStack(alignment: .leading, spacing: 14) {
                DriveStreamIssueView(
                    issue: issue,
                    recoveryEnabled: !controller.isBusy,
                    recoveryAction: {
                        presentedIssue = nil
                        controller.recoverFromMountIssue()
                    }
                )
                HStack {
                    Button("Open Logs") { controller.openLogs() }
                    Spacer()
                    Button("Done") { presentedIssue = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .controlSize(.small)
            }
            .padding(20)
            .frame(width: 440)
        }
        .confirmationDialog(
            "Remove your Google account?",
            isPresented: $showRemoveAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Google Account", role: .destructive) {
                performRemoveAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DriveStream will unmount the volume and delete its private rclone remotes and Keychain secrets. Files in Google Drive are not deleted.")
        }
        .confirmationDialog(
            "Restart Finder?",
            isPresented: $showRestartFinderConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restart Finder", role: .destructive) {
                controller.restartFinder()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Finder will close its open windows and relaunch. This applies Desktop and sidebar preference changes immediately.")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if isApplying {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                Text("Applying settings and restarting the volume…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else if let validation = draft.validationError {
                Label(validation, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if controller.isMounted {
                Text(draft.mountProfileDiffers(from: controller.config) ? "Saving restarts the volume after pending writes are checked." : "These changes can apply without restarting mounted files.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Changes are stored locally on this Mac.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Close") {
                if let onClose {
                    onClose()
                } else {
                    NSApp.keyWindow?.close()
                }
            }
            .keyboardShortcut(.cancelAction)

            Button(isApplying ? "Applying…" : "Save Changes") {
                applySettings()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: Validation

    private var canApply: Bool {
        !isApplying && !controller.isBusy && draft.validationError == nil
    }

    // MARK: Actions

    private func applySettings() {
        guard canApply else { return }
        isApplying = true
        Task { @MainActor in
            do {
                try await controller.applySettings(draft)
                draft = controller.config
                presentAlert(
                    title: "Settings Saved",
                    message: controller.isMounted
                        ? "DriveStream remounted the volume with the new settings."
                        : "Your changes will be used the next time you mount Google Drive."
                )
            } catch {
                if let issue = controller.mountIssue {
                    presentedIssue = issue
                } else {
                    presentAlert(title: "Couldn’t Apply Settings", message: error.localizedDescription)
                }
            }
            isApplying = false
        }
    }

    private func performReconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true
        Task { @MainActor in
            do {
                try await controller.reconnectGoogleDrive()
                draft = controller.config
                presentAlert(
                    title: "Google Drive Reconnected",
                    message: "A fresh OAuth token was saved. The volume was remounted if it was mounted."
                )
            } catch {
                presentAlert(title: "Reconnect Failed", message: error.localizedDescription)
            }
            isReconnecting = false
        }
    }

    private func performRemoveAccount() {
        Task { @MainActor in
            do {
                try await controller.removeGoogleAccount()
                draft = controller.config
                presentAlert(
                    title: "Google Account Removed",
                    message: "The private remotes and Keychain secrets were removed. Files in Google Drive were not touched."
                )
            } catch {
                presentAlert(title: "Couldn’t Remove Account", message: error.localizedDescription)
            }
        }
    }

    private func performRcloneInstall() {
        Task { @MainActor in
            let success = await dependencies.prepare(forceReinstall: dependencies.isRcloneReady)
            if success {
                presentAlert(
                    title: "rclone Ready",
                    message: dependencies.installation?.displayVersion ?? "The official rclone binary is installed."
                )
            } else {
                presentAlert(
                    title: "rclone Install Failed",
                    message: dependencies.lastError ?? "The binary could not be installed."
                )
            }
        }
    }

    private func performMacFUSEInstall() {
        guard !isInstallingMacFUSE else { return }
        isInstallingMacFUSE = true
        Task { @MainActor in
            do {
                let url = try await dependencies.installOrUpdateMacFUSE()
                presentAlert(
                    title: "macFUSE Installer Opened",
                    message: "The verified installer is at \(url.path). Follow the installer prompts, allow the system extension in System Settings if asked, then restart DriveStream before mounting."
                )
            } catch {
                presentAlert(title: "Couldn’t Download macFUSE", message: error.localizedDescription)
            }
            isInstallingMacFUSE = false
        }
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

private enum SettingsTab: Hashable, CaseIterable, Identifiable {
    case general
    case performance
    case account
    case advanced

    var id: Self { self }
}
