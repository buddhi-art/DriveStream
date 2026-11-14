import SwiftUI

/// Shared error presentation for the menu bar and Setup Assistant. Ordinary
/// recovery remains readable; lengthy logs live behind a keyboard-accessible
/// native disclosure instead of crowding the first screen of the error.
struct DriveStreamIssueView: View {
    let issue: DriveStreamIssue
    var recoveryEnabled = true
    var recoveryAction: (() -> Void)?
    var dismissAction: (() -> Void)?

    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(issue.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let dismissAction {
                    Button(action: dismissAction) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss error")
                    .help("Dismiss this message")
                }
            }
            if !issue.details.isEmpty {
                DisclosureGroup("Show Details", isExpanded: $showsDetails) {
                    ScrollView([.vertical, .horizontal]) {
                        Text(issue.details)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 140)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Redacted rclone diagnostic details")
                    .padding(.top, 4)
                }
                .font(.system(size: 11))
            }
            if let recoveryAction {
                Button(recoveryTitle, action: recoveryAction)
                    .controlSize(.small)
                    .disabled(!recoveryEnabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var recoveryTitle: String {
        switch issue.recovery {
        case .retryMount: return "Try Again"
        case .retryUnmount: return "Retry Unmount"
        case .openSetup: return "Open Setup Assistant"
        case .openSettings: return "Open Settings"
        }
    }
}
