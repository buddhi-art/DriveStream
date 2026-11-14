import SwiftUI

enum OnboardingStep: Int, CaseIterable, Hashable {
    case welcome
    case account
    case encryption
    case finish

    var shortTitle: String {
        switch self {
        case .welcome: return "Welcome"
        case .account: return "Account"
        case .encryption: return "Privacy"
        case .finish: return "Mount"
        }
    }
}

struct OnboardingHeader: View {
    let step: OnboardingStep
    let isFinishing: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.10, green: 0.34, blue: 0.92),
                                    Color(red: 0.24, green: 0.60, blue: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text("DriveStream")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Your Google Drive, at Finder speed")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Set Up Later") {
                    onClose()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .disabled(isFinishing)
            }

            stepIndicator
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(Array(OnboardingStep.allCases.enumerated()), id: \.element) { index, item in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.10))
                            .frame(width: 18, height: 18)
                        if item.rawValue < step.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(item.rawValue + 1)")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(item.rawValue <= step.rawValue ? .white : .secondary)
                        }
                    }
                    Text(item.shortTitle)
                        .font(.system(size: 10, weight: item == step ? .semibold : .regular))
                        .foregroundStyle(item == step ? .primary : .secondary)
                }
                if index < OnboardingStep.allCases.count - 1 {
                    Rectangle()
                        .fill(item.rawValue < step.rawValue ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.10))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                }
            }
        }
    }
}

struct OnboardingCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

struct FeatureRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10.2))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct OnboardingSummaryRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

struct DependencyIcon: View {
    let phase: DependencyPhase

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor.opacity(0.13))
                .frame(width: 28, height: 28)
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(backgroundColor)
        }
    }

    private var symbolName: String {
        switch phase {
        case .ready: return "checkmark"
        case .failed: return "exclamationmark"
        case .checking, .downloading(_), .extracting: return "arrow.down"
        case .idle: return "shippingbox"
        }
    }

    private var backgroundColor: Color {
        switch phase {
        case .ready: return .green
        case .failed: return .red
        case .checking, .downloading(_), .extracting: return .blue
        case .idle: return .secondary
        }
    }
}
