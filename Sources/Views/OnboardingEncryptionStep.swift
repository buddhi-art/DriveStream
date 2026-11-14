import SwiftUI

struct OnboardingEncryptionStep: View {
    @Binding var enableEncryption: Bool
    @Binding var cryptPassword: String
    @Binding var cryptSaltPassword: String
    @Binding var showCryptPasswords: Bool

    let existingCryptConfigured: Bool
    let hasStoredEncryptionPassword: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Protect your files")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("Client-side encryption is optional. Passwords are saved in the login Keychain. rclone needs reversibly obscured copies in its private 0600 config; protect that config as carefully as a password.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            OnboardingCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $enableEncryption) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable end-to-end encryption")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Uses rclone crypt with standard filename encryption and directory name encryption.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    if enableEncryption {
                        if existingCryptConfigured {
                            Label("The encrypted remote is already configured.", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.green)
                        }
                        if hasStoredEncryptionPassword {
                            Label("The existing encryption password is stored in the macOS Keychain.", systemImage: "key.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else if existingCryptConfigured {
                            Label("No Keychain copy was found. Leave the password blank to keep using the existing rclone config, or re-enter the exact existing password to restore it to the Keychain.", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 8) {
                            Text(showCryptPasswords ? "Passwords are visible" : "Passwords are hidden")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button {
                                showCryptPasswords.toggle()
                            } label: {
                                Label(showCryptPasswords ? "Hide" : "Show", systemImage: showCryptPasswords ? "eye.slash" : "eye")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }

                        LabeledField(title: "Encryption password") {
                            Group {
                                if showCryptPasswords {
                                    TextField(existingCryptConfigured ? "Leave blank to keep the existing password" : "At least 8 characters", text: $cryptPassword)
                                } else {
                                    SecureField(existingCryptConfigured ? "Leave blank to keep the existing password" : "At least 8 characters", text: $cryptPassword)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 340)
                        }

                        LabeledField(title: "Salt password (optional)") {
                            Group {
                                if showCryptPasswords {
                                    TextField("Optional second password", text: $cryptSaltPassword)
                                } else {
                                    SecureField("Optional second password", text: $cryptSaltPassword)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 340)
                        }

                        if existingCryptConfigured && (!cryptPassword.isEmpty || !cryptSaltPassword.isEmpty) {
                            Label("Changing the encryption password makes files written with the previous password unreadable. Only do this when you intend to re-key the remote.", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !existingCryptConfigured && cryptPassword.isEmpty {
                            Label("Enter at least 8 characters to enable encryption, or turn the toggle off to mount without encryption.", systemImage: "info.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text("If you enable crypt on an existing unencrypted Drive, only files written through the encrypted remote will be readable through it. Keep the unencrypted remote disabled for new writes if your existing library is plaintext.")
                            .font(.system(size: 9.8))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Your Drive is mounted directly. Finder sees your original filenames and Google can read file contents. Encryption can be enabled later in the Setup Assistant.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().opacity(0.5)

                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.green)
                        Text("The encryption password and optional salt password are saved in the macOS Keychain by KeychainHelper. rclone’s config contains reversibly obscured forms and is chmod 0600.")
                            .font(.system(size: 9.8))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
