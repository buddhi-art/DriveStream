import SwiftUI

/// A queue observation, not a claim of remote durability or an offline pin lease.
struct PendingWritesView: View {
    let snapshot: UploadSafetySnapshot
    var checking = false
    var refreshAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: snapshot.state == .idleObserved ? "checkmark.circle" : "arrow.up.circle")
                    .foregroundStyle(snapshot.state == .blocked ? Color.orange : Color.blue)
                    .accessibilityHidden(true)
                Text(snapshot.title).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                if checking { ProgressView().controlSize(.small) }
                else if let refreshAction {
                    Button(action: refreshAction) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Check pending uploads")
                }
            }
            if let count = snapshot.pendingFiles, count > 0 {
                Text("\(count) file\(count == 1 ? "" : "s") · \(ByteFormat.bytes(snapshot.pendingBytes)) queued")
                    .font(.system(size: 11).monospacedDigit())
            }
            Text(snapshot.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(snapshot.state == .blocked ? Color.orange.opacity(0.10) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
