import SwiftUI

struct OnboardingAccountStep: View {
    @ObservedObject var controller: MountController
    @ObservedObject var dependencies: DependencyManager
    @Binding var volumeName: String
    @Binding var useCustomOAuth: Bool
    @Binding var clientID: String
    @Binding var clientSecret: String
    @Binding var showClientSecret: Bool
    @Binding var showOAuthGuide: Bool

    let isConnecting: Bool
    let authSettingsChanged: Bool
    let connectedAccountSubtitle: String
    let onSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Connect Google Drive")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("DriveStream opens Google's sign-in page in your browser, then stores the token in its own private config. Your password never touches DriveStream.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.isGoogleConnected {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Google Drive is connected")
                            .font(.system(size: 12, weight: .semibold))
                        Text(connectedAccountSubtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            OnboardingCard {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledField(title: "Volume name in Finder") {
                        TextField("Google Drive", text: $volumeName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }

                    Divider().opacity(0.5)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Google sign-in method")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Picker("Google sign-in method", selection: $useCustomOAuth) {
                            Text("Personal OAuth client").tag(true)
                            Text("rclone default").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 330)
                        Text(useCustomOAuth
                             ? "Recommended. A personal Client ID gives DriveStream its own Google API quota, reducing shared-client rate-limiting during 4K video scrubbing and heavy Finder browsing. Google account limits still apply."
                             : "No Google Cloud setup. DriveStream falls back to rclone's shared credentials, which can be rate-limited during 4K video scrubbing or heavy Finder browsing.")
                            .font(.system(size: 9.8))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if useCustomOAuth {
                        VStack(alignment: .leading, spacing: 9) {
                            LabeledField(title: "Client ID") {
                                TextField("1234567890-abc.apps.googleusercontent.com", text: $clientID)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .frame(maxWidth: 360)
                            }
                            LabeledField(title: "Client Secret") {
                                HStack(spacing: 6) {
                                    if showClientSecret {
                                        TextField(storedClientSecretPlaceholder, text: $clientSecret)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(size: 10.5, design: .monospaced))
                                    } else {
                                        SecureField(storedClientSecretPlaceholder, text: $clientSecret)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    Button {
                                        showClientSecret.toggle()
                                    } label: {
                                        Image(systemName: showClientSecret ? "eye.slash" : "eye")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(showClientSecret ? "Hide client secret" : "Show client secret")
                                }
                                .frame(maxWidth: 360)
                            }

                            Text("A personal OAuth client reduces shared-client quota pressure during 4K video scrubbing and Finder browsing; it cannot remove Google's per-account limits. DriveStream saves the client secret in the macOS Keychain. rclone also needs a copy in its private 0600 config to refresh tokens.")
                                .font(.system(size: 9.8))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            DisclosureGroup(isExpanded: $showOAuthGuide) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("1. Open Google Cloud Console and create or select a project.")
                                    Text("2. Enable the Google Drive API for that project.")
                                    Text("3. Configure the OAuth consent screen, then add your Google account as a test user while the app is in testing.")
                                    Text("4. Create credentials → OAuth client ID → Desktop app.")
                                    Text("5. Paste the Client ID and Client Secret here, then click Sign in with Google.")
                                    Text("6. Complete the browser sign-in. rclone uses the loopback receiver at http://127.0.0.1:53682/.")
                                }
                                .font(.system(size: 9.8))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)

                                HStack(spacing: 12) {
                                    Link("Google Cloud Console ↗", destination: URL(string: "https://console.cloud.google.com/")!)
                                    Link("Create OAuth Client ↗", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                                    Link("Enable Drive API ↗", destination: URL(string: "https://console.cloud.google.com/apis/library/drive.googleapis.com")!)
                                }
                                .font(.system(size: 10, weight: .medium))
                                .padding(.top, 3)
                            } label: {
                                Label("How to create a Desktop OAuth client", systemImage: "questionmark.circle")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }

                    HStack(spacing: 10) {
                        Button {
                            onSignIn()
                        } label: {
                            HStack(spacing: 6) {
                                if isConnecting || controller.isConnecting {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "person.badge.key.fill")
                                }
                                Text(signInButtonTitle)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isConnecting || controller.isConnecting || !dependencies.isRcloneReady)

                        if let quota = controller.telemetry.about {
                            Text("\(ByteFormat.bytes(quota.used)) used of \(ByteFormat.bytes(quota.effectiveTotal))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if isConnecting || controller.isConnecting {
                        Text(controller.connectionMessage ?? "Waiting for Google authorization in your browser…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    if authSettingsChanged && !isConnecting && !controller.isConnecting {
                        Label("Sign-in method changed. Reconnect to apply the new credentials before continuing.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                }
            }
        }
    }

    private var storedClientSecretPlaceholder: String {
        if controller.config.usesCustomOAuth {
            return "Leave blank to keep the stored secret"
        }
        return "Paste your OAuth client secret"
    }

    private var signInButtonTitle: String {
        if controller.isGoogleConnected {
            return "Reconnect Google Drive"
        }
        return "Sign in with Google"
    }
}
