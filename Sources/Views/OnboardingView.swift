import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject private var controller: MountController
    @ObservedObject private var dependencies: DependencyManager

    private let onClose: (() -> Void)?

    @State private var step: OnboardingStep = .welcome
    @State private var volumeName: String
    @State private var useCustomOAuth: Bool
    @State private var clientID: String
    @State private var clientSecret: String
    @State private var showClientSecret = false
    @State private var showOAuthGuide = false
    @State private var enableEncryption: Bool
    @State private var cryptPassword = ""
    @State private var cryptSaltPassword = ""
    @State private var showCryptPasswords = false
    @State private var autoMount: Bool
    @State private var mountBackend: MountBackendPreference
    @State private var mountLocation: MountLocationPreference
    @State private var cacheMaxSize: String
    @State private var isConnecting = false
    @State private var isFinishing = false
    @State private var inlineError: String?
    @State private var didRequestDependencies = false

    init(controller: MountController, onClose: (() -> Void)? = nil) {
        self._controller = ObservedObject(wrappedValue: controller)
        self._dependencies = ObservedObject(wrappedValue: controller.dependencyManager)
        self.onClose = onClose
        let config = controller.config
        self._volumeName = State(initialValue: config.volumeName)
        self._useCustomOAuth = State(initialValue: config.usesCustomOAuth)
        self._clientID = State(initialValue: config.clientID)
        self._clientSecret = State(initialValue: "")
        self._enableEncryption = State(initialValue: config.useEncryption)
        self._autoMount = State(initialValue: config.autoMountOnLaunch)
        self._mountBackend = State(initialValue: config.mountBackend)
        self._mountLocation = State(initialValue: config.mountLocation)
        self._cacheMaxSize = State(initialValue: config.cacheMaxSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader(step: step, isFinishing: isFinishing, onClose: closeWindow)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    stepContent
                    if let inlineError {
                        if let issue = controller.mountIssue {
                            DriveStreamIssueView(
                                issue: issue,
                                recoveryEnabled: !controller.isBusy,
                                recoveryAction: { controller.recoverFromMountIssue() }
                            )
                            .id(issue.id)
                        } else {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(inlineError)
                                    .font(.system(size: 11))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .frame(maxWidth: 580, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 30)
                .padding(.vertical, 22)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 700, height: 660)
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [Color.blue.opacity(0.08), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
            }
        )
        .task {
            guard !didRequestDependencies else { return }
            didRequestDependencies = true
            if !dependencies.isRcloneReady {
                _ = await dependencies.prepare()
            }
            dependencies.refreshFuseAvailability()
            if !controller.remoteIsConfigured {
                controller.refreshConnectionState()
            }
        }
    }

    // MARK: Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            OnboardingWelcomeStep(
                dependencies: dependencies,
                onPrepareRclone: { Task { _ = await dependencies.prepare(forceReinstall: false) } }
            )
        case .account:
            OnboardingAccountStep(
                controller: controller, dependencies: dependencies,
                volumeName: $volumeName, useCustomOAuth: $useCustomOAuth,
                clientID: $clientID, clientSecret: $clientSecret,
                showClientSecret: $showClientSecret, showOAuthGuide: $showOAuthGuide,
                isConnecting: isConnecting, authSettingsChanged: authSettingsChanged,
                connectedAccountSubtitle: connectedAccountSubtitle,
                onSignIn: signInWithGoogle
            )
        case .encryption:
            OnboardingEncryptionStep(
                enableEncryption: $enableEncryption,
                cryptPassword: $cryptPassword, cryptSaltPassword: $cryptSaltPassword,
                showCryptPasswords: $showCryptPasswords,
                existingCryptConfigured: enableEncryption && existingCryptConfigured,
                hasStoredEncryptionPassword: enableEncryption && controller.hasStoredEncryptionPassword
            )
        case .finish:
            OnboardingFinishStep(
                controller: controller, dependencies: dependencies, autoMount: $autoMount,
                connectedAccountSubtitle: connectedAccountSubtitle,
                volumeName: volumeName, mountLocation: mountLocation,
                mountBackend: mountBackend, cacheMaxSize: cacheMaxSize,
                enableEncryption: enableEncryption
            )
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .welcome {
                Button("Back") {
                    inlineError = nil
                    if let previous = OnboardingStep(rawValue: step.rawValue - 1) {
                        step = previous
                    }
                }
                .controlSize(.small)
                .disabled(isConnecting || controller.isConnecting || isFinishing)
            }

            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Button(primaryButtonTitle) {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!primaryEnabled)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(.bar)
    }

    private var primaryButtonTitle: String {
        switch step {
        case .welcome: return "Continue"
        case .account: return "Continue"
        case .encryption: return "Continue"
        case .finish:
            if isFinishing { return "Mounting…" }
            return autoMount ? "Mount Google Drive" : "Finish Setup"
        }
    }

    private var primaryEnabled: Bool {
        if isFinishing { return false }
        switch step {
        case .welcome:
            return dependencies.isRcloneReady
        case .account:
            return controller.isGoogleConnected && !authSettingsChanged && !(isConnecting || controller.isConnecting)
        case .encryption:
            guard enableEncryption else { return true }
            // Existing encryption can continue from rclone.conf even if the Keychain
            // copy is missing; forcing a blind re-entry could re-key existing data
            // with a mistyped password. New encryption still requires 8+ characters.
            if existingCryptConfigured && cryptPassword.isEmpty { return true }
            if cryptPassword.count < 8 { return false }
            if !cryptSaltPassword.isEmpty && cryptSaltPassword.count < 8 { return false }
            return true
        case .finish:
            return controller.isGoogleConnected && !isFinishing && !controller.isBusy
        }
    }

    private func advance() {
        inlineError = nil
        switch step {
        case .welcome:
            guard dependencies.isRcloneReady else { return }
            step = .account
        case .account:
            guard controller.isGoogleConnected else {
                inlineError = "Connect Google Drive before continuing."
                return
            }
            guard !authSettingsChanged else {
                inlineError = "Reconnect Google Drive to apply the changed sign-in method."
                return
            }
            step = .encryption
        case .encryption:
            if enableEncryption,
               !existingCryptConfigured,
               cryptPassword.count < 8 {
                inlineError = "Choose an encryption password with at least 8 characters."
                return
            }
            step = .finish
        case .finish:
            finishSetup()
        }
    }

    private func signInWithGoogle() {
        guard !isConnecting else { return }
        inlineError = nil
        let credentials: GoogleOAuthCredentials
        do {
            credentials = try GoogleOAuthCredentials.resolve(
                useCustomClient: useCustomOAuth,
                clientID: clientID, enteredSecret: clientSecret,
                storedClientID: controller.config.usesCustomOAuth ? controller.config.clientID : "",
                storedSecret: controller.configService.storedClientSecret()
            )
        } catch {
            inlineError = error.localizedDescription
            return
        }
        isConnecting = true
        Task { @MainActor in
            do {
                try await controller.connectGoogleDrive(
                    useCustomCredentials: useCustomOAuth,
                    clientID: credentials.clientID,
                    clientSecret: credentials.clientSecret
                )
                clientSecret = ""
                isConnecting = false
            } catch is CancellationError {
                isConnecting = false
            } catch {
                inlineError = error.localizedDescription
                isConnecting = false
            }
        }
    }

    private func finishSetup() {
        guard !isFinishing else { return }
        inlineError = nil
        isFinishing = true
        Task { @MainActor in
            do {
                try await controller.completeOnboarding(
                    volumeName: volumeName,
                    enableEncryption: enableEncryption,
                    cryptPassword: cryptPassword,
                    cryptSaltPassword: cryptSaltPassword,
                    autoMount: autoMount,
                    mountBackend: mountBackend,
                    mountLocation: mountLocation,
                    cacheMaxSize: cacheMaxSize
                )
                isFinishing = false
                closeWindow()
            } catch {
                inlineError = error.localizedDescription
                isFinishing = false
            }
        }
    }

    private func closeWindow() {
        controller.cancelGoogleConnection()
        clientSecret = ""
        cryptPassword = ""
        cryptSaltPassword = ""
        if let onClose {
            onClose()
        } else {
            NSApp.keyWindow?.close()
        }
    }

    // MARK: Derived values

    private var authSettingsChanged: Bool {
        guard controller.isGoogleConnected else { return false }
        if useCustomOAuth != controller.config.usesCustomOAuth { return true }
        guard useCustomOAuth else { return false }
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedID != controller.config.clientID { return true }
        // A newly entered secret with the same client ID also indicates an intended
        // credential change; require Reconnect before leaving the account step.
        return !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var existingCryptConfigured: Bool {
        controller.configService.profile(for: controller.config.cryptRemoteName)?.isCrypt == true
    }

    private var connectedAccountSubtitle: String {
        if let account = controller.accountLabel ?? controller.config.accountEmail.nonEmpty {
            return account
        }
        if let about = controller.telemetry.about {
            return "\(ByteFormat.bytes(about.used)) of \(ByteFormat.bytes(about.effectiveTotal)) used"
        }
        return "Connected with a private rclone remote"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
