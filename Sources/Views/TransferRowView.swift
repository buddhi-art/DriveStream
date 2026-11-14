import SwiftUI

struct TransferRowView: View {
    let item: TransferItem

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 24, height: 24)
                Image(systemName: item.direction.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(item.displaySpeed)
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if item.totalBytes > 0 {
                    ProgressView(value: item.progress)
                        .tint(tint)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .tint(tint)
                        .controlSize(.small)
                }

                HStack(spacing: 4) {
                    Text(item.direction.title)
                    Text("·")
                    if item.totalBytes > 0 {
                        Text("\(ByteFormat.bytes(item.completedBytes)) / \(ByteFormat.bytes(item.totalBytes))")
                    } else {
                        Text(ByteFormat.bytes(item.completedBytes))
                    }
                    Spacer(minLength: 0)
                    if let eta = item.eta, eta > 0 {
                        Text("ETA \(ByteFormat.duration(eta))")
                    }
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .help(item.path.isEmpty ? item.name : item.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.direction.title) \(item.name), \(ByteFormat.percent(item.progress)), \(item.displaySpeed)")
    }

    private var tint: Color {
        switch item.direction {
        case .upload: return .blue
        case .download: return .teal
        case .other: return .purple
        }
    }
}
