import SwiftUI

/// Root selection stays part of the Settings draft; merely browsing the list never
/// changes rclone.conf or interrupts a mounted volume.
struct SettingsDriveRootSection: View {
    @Binding var draft: StreamConfig
    @ObservedObject var controller: MountController
    @State private var drives: [GoogleSharedDrive] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var refreshID = UUID()

    private struct RequestID: Hashable {
        let account: UUID
        let refresh: UUID
        let connected: Bool
    }

    private var requestID: RequestID {
        RequestID(account: controller.accountGeneration, refresh: refreshID, connected: controller.isGoogleConnected)
    }

    var body: some View {
        SettingsSection(title: "Mount root", subtitle: "Choose what appears at the top of your Finder volume.") {
            Picker("Drive", selection: $draft.sharedDriveID) {
                Text("My Drive").tag("")
                ForEach(drives) { drive in
                    Text(optionLabel(for: drive)).tag(drive.id)
                        .help("\(drive.name)\nShared Drive ID: \(drive.id)")
                }
                if !draft.sharedDriveID.isEmpty && !drives.contains(where: { $0.id == draft.sharedDriveID }) {
                    Text("Shared Drive · \(shortID(draft.sharedDriveID))").tag(draft.sharedDriveID)
                }
            }
            .controlSize(.small)
            .disabled(!controller.isGoogleConnected || controller.isBusy)
            .accessibilityHint("Select My Drive or one Shared Drive. Save Changes applies the selection.")

            HStack(alignment: .center, spacing: 8) {
                if isLoading {
                    ProgressView().controlSize(.small)
                    Text("Loading Shared Drives…")
                } else if !controller.isGoogleConnected {
                    Text("Sign in to Google Drive to load your Shared Drives.")
                } else if hasLoaded && drives.isEmpty {
                    Text("No Shared Drives were returned for this account.")
                } else if hasLoaded {
                    Text("Shared Drives available to your signed-in account.")
                }
                Spacer(minLength: 8)
                Button("Refresh List") { refreshID = UUID() }
                    .controlSize(.small)
                    .disabled(isLoading || !controller.isGoogleConnected || controller.isBusy)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Enter a Shared Drive ID instead") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Shared Drive ID", text: $draft.sharedDriveID, prompt: Text("Paste the ID, not a Drive URL"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Shared Drive ID")
                        .disabled(!controller.isGoogleConnected || controller.isBusy)
                    if !draft.normalizedSharedDriveID.isEmpty && !GoogleSharedDrive.validID(draft.normalizedSharedDriveID) {
                        Label(DriveRootError.invalidID.localizedDescription, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    } else {
                        Text("Use this fallback if the drive is missing from the list. Your account must already have access. Clear the field to use My Drive.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))

            Text("A Shared Drive replaces My Drive as the mount root. It does not add “Shared with me.” Saving verifies access and checks pending writes before switching. Pinned selections are reset; previous cached data is kept separately on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: requestID) { await loadDrives(for: requestID) }
    }

    private func shortID(_ id: String) -> String {
        id.count > 24 ? String(id.prefix(12)) + "…" + String(id.suffix(6)) : id
    }

    private func optionLabel(for drive: GoogleSharedDrive) -> String {
        let name = drive.name.count > 80 ? String(drive.name.prefix(80)) + "…" : drive.name
        return drives.contains(where: { $0.id != drive.id && $0.name == drive.name })
            ? name + " · " + shortID(drive.id) : name
    }

    @MainActor
    private func loadDrives(for request: RequestID) async {
        guard !Task.isCancelled, request == requestID else { return }
        drives = []
        hasLoaded = false
        loadError = nil
        isLoading = false
        guard request.connected else { return }
        isLoading = true
        defer { if request == requestID { isLoading = false } }
        do {
            let result = try await controller.availableSharedDrives()
            try Task.checkCancellation()
            guard request == requestID else { return }
            drives = result.sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
            hasLoaded = true
        } catch is CancellationError {
            // A new account, refresh, or disappearing view owns the next result.
        } catch {
            guard request == requestID else { return }
            loadError = (error as? DriveRootError)?.localizedDescription ?? DriveRootError.listingFailed.localizedDescription
        }
    }
}
