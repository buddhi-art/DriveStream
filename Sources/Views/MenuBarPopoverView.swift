import AppKit
import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var controller: MountController

    init(controller: MountController) {
        self.controller = controller
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()
                .opacity(0.4)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if !controller.isGoogleConnected {
                        setupBanner
                    }
                    if controller.isIndexing {
                        indexingBanner
                    }
                    if let issue = controller.mountIssue {
                        DriveStreamIssueView(
                            issue: issue,
                            recoveryEnabled: !controller.isBusy,
                            recoveryAction: { controller.recoverFromMountIssue() },
                            dismissAction: { controller.dismissError() }
                        )
                        .id(issue.id)
                    } else if let error = controller.errorMessage {
                        errorBanner(error)
                    }
                    if let toast = controller.toastMessage {
                        toastBanner(toast)
                    }
                    cloudCard
                    if controller.isMounted {
                        PendingWritesView(snapshot: controller.uploadSafety, checking: controller.isCheckingWrites,
                                          refreshAction: { Task { await controller.refreshWriteSafetyNow() } })
                    }
                    if controller.connectivity == .unavailable || controller.isSleeping {
                        Text(controller.isSleeping
                             ? "Mount preserved during sleep. Uploads resume when the Mac and connection are available."
                             : "Offline: the mount stays attached. Cached files may be usable; uncached data still needs a connection.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    cacheCard
                    if let warning = controller.telemetryWarning {
                        telemetryWarningBanner(warning)
                    }
                    liveActivity
                    if !controller.telemetry.transfers.isEmpty {
                        transfersSection
                    }
                    if let pinProgress = controller.pinProgress {
                        pinningBanner(pinProgress)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .frame(height: 390)

            Divider()
                .opacity(0.55)

            quickControls
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            footer
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(width: 380)
        .background(
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .onAppear {
            controller.refreshTelemetryNow()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.34, blue: 0.92),
                                Color(red: 0.24, green: 0.60, blue: 1.00)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .frame(width: 42, height: 42)
            .overlay(alignment: .bottomTrailing) {
                StatusDot(status: controller.state.status, isIndexing: controller.isIndexing)
                    .offset(x: 2, y: 2)
            }
            .shadow(color: .black.opacity(0.16), radius: 5, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("DriveStream")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Text(controller.statusTitle)
                    Text("•")
                    Text(controller.volumeName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button { controller.showSidebarHelp() } label: {
                Image(systemName: "sidebar.left").frame(width: 24, height: 26)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Keep DriveStream in Finder")
            .help("Keep DriveStream in Finder")
            Button {
                controller.openInFinder()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!controller.isMounted)
            .help("Open in Finder")
            .accessibilityLabel("Open in Finder")
        }
    }

    // MARK: Banners

    private var setupBanner: some View {
        PopoverPanel {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect Google Drive")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Authorize your account once, then mount it in Finder.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button("Set Up") {
                    controller.presentSetupAssistant()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var indexingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.85)
            VStack(alignment: .leading, spacing: 2) {
                Text("Indexing directory tree in RAM...")
                    .font(.system(size: 12, weight: .semibold))
                Text("Finder folders open from memory as the tree is warmed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let started = controller.indexingStartedAt {
                Text(ByteFormat.duration(Date().timeIntervalSince(started)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            LinearGradient(
                colors: [Color.orange.opacity(0.16), Color.yellow.opacity(0.08)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
                .padding(.top, 1)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                controller.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .padding(3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss error")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func telemetryWarningBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live activity needs attention", systemImage: "wifi.exclamationmark")
                .font(.system(size: 11, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Retry Now") { controller.refreshTelemetryNow() }
                    .controlSize(.small)
                    .disabled(controller.telemetryRetryInProgress || controller.isBusy)
                if controller.telemetryRetryInProgress {
                    ProgressView().controlSize(.small)
                    Text("Retrying…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func toastBanner(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12))
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Storage cards

    private var cloudCard: some View {
        PopoverPanel {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                    Text("GOOGLE DRIVE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let account = controller.accountLabel ?? controller.config.accountEmail.nonEmpty {
                        Text(account)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let about = controller.telemetry.about {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ByteFormat.bytes(about.used))
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("of \(ByteFormat.bytes(about.effectiveTotal)) used")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(ByteFormat.percent(about.usedFraction))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    MeterBar(
                        fraction: about.usedFraction,
                        tint: LinearGradient(
                            colors: [Color(red: 0.20, green: 0.47, blue: 1.0), Color(red: 0.35, green: 0.78, blue: 1.0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        accessibilityLabel: "Google Drive storage used"
                    )
                    if let warning = controller.quotaWarning {
                        Label(warning, systemImage: "exclamationmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Text(quotaFootnote(about))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if controller.state.backend != nil {
                            Text(controller.state.backend?.shortName ?? "")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else if controller.isGoogleConnected {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                        Text("Loading Google Drive quota…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    HStack {
                        Text("Connect your account to see its reported storage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Connect") {
                            controller.presentSetupAssistant()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func quotaFootnote(_ about: RcloneAbout) -> String {
        if let free = about.free, free > 0 {
            return "\(ByteFormat.bytes(free)) available"
        }
        if let trashed = about.trashed, trashed > 0 {
            return "Includes \(ByteFormat.bytes(trashed)) in trash"
        }
        return "Quota reported by Google Drive"
    }

    private var cacheCard: some View {
        PopoverPanel {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("LOCAL SSD CACHE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if controller.pinnedCount > 0 {
                        Label("\(controller.pinnedCount) warmed", systemImage: "pin.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(ByteFormat.bytes(controller.telemetry.cacheBytes))
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("/ \(controller.config.normalizedCacheMaxSize) max on Mac")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(ByteFormat.percent(cacheFraction))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                MeterBar(
                    fraction: cacheFraction,
                    tint: LinearGradient(
                        colors: [Color.orange, Color.yellow],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    accessibilityLabel: "Local cache used"
                )

                HStack(alignment: .center, spacing: 8) {
                    Text(cacheFootnote)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if controller.freeUpInProgress {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }
                    Button {
                        Task { await controller.freeUpSpaceNow() }
                    } label: {
                        Label("Request Cleanup", systemImage: "arrow.down.circle")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(controller.isMounted ? Color.blue : Color.secondary)
                    .disabled(!controller.isMounted || controller.freeUpInProgress)
                    .help("Invalidate directory metadata. File chunks are reclaimed separately under rclone's cache policy.")
                }
            }
        }
    }

    private var cacheFraction: Double? {
        guard controller.cacheLimitBytes > 0 else { return nil }
        return min(max(Double(controller.telemetry.cacheBytes) / Double(controller.cacheLimitBytes), 0), 1)
    }

    private var cacheFootnote: String {
        var parts: [String] = []
        if controller.telemetry.cachedFileCount > 0 {
            parts.append("\(controller.telemetry.cachedFileCount) files")
        }
        if controller.telemetry.queuedUploads > 0 {
            parts.append("\(controller.telemetry.queuedUploads) uploads queued")
        }
        if controller.pinProgress != nil {
            parts.append("pinning…")
        }
        if parts.isEmpty {
            parts.append(controller.isMounted ? "VFS cache is ready" : "No active mount")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Telemetry

    private var liveActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LIVE ACTIVITY")
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(telemetryTimestamp)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                MetricTile(
                    title: "Read",
                    value: ByteFormat.speed(controller.telemetry.readBytesPerSecond),
                    symbol: "arrow.down",
                    tint: .teal
                )
                .help("Streaming read throughput, including VFS read-ahead")

                MetricTile(
                    title: "Write",
                    value: ByteFormat.speed(controller.telemetry.writeBytesPerSecond),
                    symbol: "arrow.up",
                    tint: .blue
                )
                .help("Background write-back upload throughput")

                MetricTile(
                    title: "Activity",
                    value: "\(controller.telemetry.activeStreams)",
                    symbol: "waveform.path.ecg",
                    tint: .purple
                )
                .help("Derived VFS references and transfers, not an exact count of editor handles")
            }
        }
    }

    private var telemetryTimestamp: String {
        if controller.telemetry.lastUpdated == .distantPast {
            return controller.isMounted ? "Connecting…" : "Idle"
        }
        let stamp = controller.telemetry.lastUpdated.formatted(date: .omitted, time: .standard)
        return controller.telemetryIsStale ? "Last good update \(stamp)" : "Updated \(stamp)"
    }

    private var transfersSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("ACTIVE TRANSFERS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(controller.telemetry.transfers.count)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(controller.telemetry.transfers.prefix(3))) { item in
                TransferRowView(item: item)
            }
            if controller.telemetry.transfers.count > 3 {
                Text("+ \(controller.telemetry.transfers.count - 3) more transfers")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
        }
    }

    private func pinningBanner(_ progress: PinProgress) -> some View {
        PopoverPanel {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text(progress.phase == .scanning ? "Scanning for offline files…" : "Pinning files offline…")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("Cancel") {
                        controller.cancelPinning()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Text(progress.currentPath.isEmpty ? "—" : progress.currentPath)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Text("\(progress.completedFiles) files")
                    Text("·")
                    Text(ByteFormat.bytes(progress.completedBytes))
                    if progress.failedFiles > 0 {
                        Text("·")
                        Text("\(progress.failedFiles) failed")
                    }
                    Spacer()
                }
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Controls

    private var quickControls: some View {
        HStack(spacing: 6) {
            PopoverControlButton(
                title: mountButtonTitle,
                symbol: controller.hasMountSession ? "eject.fill" : "play.fill",
                isPrimary: !controller.hasMountSession && controller.isGoogleConnected,
                isEnabled: !controller.isBusy && controller.isGoogleConnected
            ) {
                Task { await controller.toggleMount() }
            }

            PopoverControlButton(
                title: "Refresh",
                symbol: "arrow.clockwise",
                isPrimary: false,
                isEnabled: controller.isMounted && !controller.refreshInProgress
            ) {
                controller.forceRefreshDirectoryTree()
            }
            .help("Force a recursive rclone vfs/refresh")

            PopoverControlButton(
                title: "Settings",
                symbol: "gearshape.fill",
                isPrimary: false,
                isEnabled: true
            ) {
                controller.presentSettings()
            }

            PopoverControlButton(
                title: "Quit",
                symbol: "power",
                isPrimary: false,
                isEnabled: true
            ) {
                controller.quitApplication()
            }
        }
    }

    private var mountButtonTitle: String {
        switch controller.state.status {
        case .preparing: return "Preparing"
        case .mounting: return "Mounting"
        case .unmounting: return "Unmounting"
        case .failed: return controller.hasMountSession ? "Retry Unmount" : "Mount"
        default: return controller.hasMountSession ? "Unmount" : "Mount"
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text("Private RC · No analytics")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(appVersion)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty {
            return "v\(version) (\(build))"
        }
        return "v\(version)"
    }
}

// MARK: - Shared popover components

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

struct PopoverPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

struct MeterBar: View {
    let fraction: Double?
    let tint: LinearGradient
    let accessibilityLabel: String

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.09))
                if let fraction {
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: max(0, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Text(ByteFormat.percent(fraction)))
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .font(.system(size: 8.5, weight: .semibold))
                    .kerning(0.55)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct PopoverControlButton: View {
    let title: String
    let symbol: String
    let isPrimary: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(foregroundStyle)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }

    private var foregroundStyle: Color {
        if isPrimary { return .white }
        return isEnabled ? .primary : .secondary
    }

    private var backgroundStyle: AnyShapeStyle {
        if isPrimary {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(Color.primary.opacity(isHovering ? 0.10 : 0.055))
    }
}

struct StatusDot: View {
    let status: MountStatus
    let isIndexing: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 12, height: 12)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .help(helpText)
        .accessibilityLabel(Text(helpText))
    }

    private var color: Color {
        if status == .failed { return .red }
        if isIndexing { return .orange }
        switch status {
        case .mounted: return .green
        case .unmounted: return .secondary
        case .preparing, .mounting, .unmounting: return .orange
        case .failed: return .red
        case .indexing: return .orange
        }
    }

    private var helpText: String {
        if status == .failed { return "DriveStream needs attention" }
        if isIndexing { return "Indexing directory tree in RAM" }
        return status.title
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
