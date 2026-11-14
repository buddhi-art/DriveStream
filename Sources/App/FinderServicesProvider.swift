import AppKit
import Foundation

/// Implements the two Finder Services declared in Info.plist.
///
/// The selectors intentionally match:
///   pinOfflineService:userData:error:
///   evictCacheService:userData:error:
@MainActor
final class FinderServicesProvider: NSObject {
    static let shared = FinderServicesProvider()

    private weak var controller: MountController?

    private override init() {
        super.init()
    }

    func attach(controller: MountController) {
        self.controller = controller
    }

    // MARK: Finder Services

    @objc func pinOfflineService(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        error.pointee = nil
        guard let controller else {
            error.pointee = "DriveStream is still starting. Try again in a moment." as NSString
            return
        }
        guard controller.isMounted else {
            error.pointee = "Mount Google Drive in DriveStream before pinning items offline." as NSString
            return
        }
        let urls = selectedFileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = "Select one or more files or folders in Finder." as NSString
            return
        }
        if let invalid = urls.first(where: { !isInsideMount($0, controller: controller) }) {
            error.pointee = "“\(invalid.lastPathComponent)” is outside the DriveStream volume." as NSString
            return
        }

        let count = urls.count
        ServiceFeedbackPresenter.shared.show(
            title: "Pinning offline",
            message: "Caching \(count) selected item\(count == 1 ? "" : "s") in the local VFS cache…",
            style: .progress
        )

        Task { @MainActor in
            do {
                let result = try await controller.pinOffline(urls: urls)
                var message = "\(result.filesRead) file\(result.filesRead == 1 ? "" : "s") • \(ByteFormat.bytes(result.bytesRead)) cached."
                if result.failedFiles > 0 {
                    message += " \(result.failedFiles) item\(result.failedFiles == 1 ? "" : "s") could not be read."
                }
                ServiceFeedbackPresenter.shared.show(
                    title: "Pinned for offline use",
                    message: message,
                    style: .success
                )
            } catch {
                ServiceFeedbackPresenter.shared.show(
                    title: "Could not pin offline",
                    message: error.localizedDescription,
                    style: .failure
                )
            }
        }
    }

    @objc func evictCacheService(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        error.pointee = nil
        guard let controller else {
            error.pointee = "DriveStream is still starting. Try again in a moment." as NSString
            return
        }
        guard controller.isMounted else {
            error.pointee = "Mount Google Drive in DriveStream before evicting local copies." as NSString
            return
        }
        let urls = selectedFileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = "Select one or more files or folders in Finder." as NSString
            return
        }
        if let invalid = urls.first(where: { !isInsideMount($0, controller: controller) }) {
            error.pointee = "“\(invalid.lastPathComponent)” is outside the DriveStream volume." as NSString
            return
        }

        ServiceFeedbackPresenter.shared.show(
            title: "Evicting local copies",
            message: "Asking rclone to release cached data for \(urls.count) item\(urls.count == 1 ? "" : "s")…",
            style: .progress
        )

        Task { @MainActor in
            do {
                let result = try await controller.evict(paths: urls)
                var message = "\(result.evictedPaths.count) item\(result.evictedPaths.count == 1 ? "" : "s") removed from the offline-cache index. rclone reclaims cached blocks under its policy."
                if !result.failures.isEmpty {
                    message += " \(result.failures.count) failed."
                }
                ServiceFeedbackPresenter.shared.show(
                    title: "Eviction requested",
                    message: message,
                    style: result.failures.isEmpty ? .success : .warning
                )
            } catch {
                ServiceFeedbackPresenter.shared.show(
                    title: "Could not evict local copy",
                    message: error.localizedDescription,
                    style: .failure
                )
            }
        }
    }

    // MARK: Pasteboard helpers

    private func selectedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []

        if let paths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String] {
            urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
        }

        if let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] {
            urls.append(contentsOf: objects.map { $0 as URL })
        }

        if let string = pasteboard.string(forType: .fileURL),
           let url = URL(string: string),
           url.isFileURL {
            urls.append(url)
        }

        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !path.isEmpty else { return false }
            return seen.insert(path).inserted
        }
    }

    private func isInsideMount(_ url: URL, controller: MountController) -> Bool {
        let mountPath = URL(fileURLWithPath: controller.mountPath).standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate == mountPath || candidate.hasPrefix(mountPath + "/")
    }
}

// MARK: - Service feedback

/// A small, non-activating heads-up panel so Finder Services can communicate results
/// without requiring Notification Center permission or stealing focus from Finder.
@MainActor
final class ServiceFeedbackPresenter {
    enum Style {
        case progress
        case success
        case warning
        case failure

        var symbolName: String {
            switch self {
            case .progress: return "hourglass"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failure: return "xmark.octagon.fill"
            }
        }

        var tintColor: NSColor {
            switch self {
            case .progress: return .controlAccentColor
            case .success: return .systemGreen
            case .warning: return .systemOrange
            case .failure: return .systemRed
            }
        }

        var soundName: String? {
            switch self {
            case .progress: return nil
            case .success: return "Glass"
            case .warning: return "Funk"
            case .failure: return "Basso"
            }
        }
    }

    static let shared = ServiceFeedbackPresenter()

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    func show(title: String, message: String, style: Style) {
        dismissWorkItem?.cancel()
        let panel = makePanelIfNeeded()
        guard let content = panel.contentView else { return }

        content.subviews.forEach { $0.removeFromSuperview() }
        let background = NSVisualEffectView(frame: content.bounds)
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        content.addSubview(background)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(
            systemSymbolName: style.symbolName,
            accessibilityDescription: title
        )
        icon.contentTintColor = style.tintColor
        icon.image = icon.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        )

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let messageLabel = NSTextField(labelWithString: message)
        messageLabel.font = .systemFont(ofSize: 11, weight: .regular)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 3
        messageLabel.preferredMaxLayoutWidth = 280
        messageLabel.cell?.wraps = true

        let textStack = NSStackView(views: [titleLabel, messageLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(icon)
        background.addSubview(textStack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            textStack.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -12)
        ])

        let width: CGFloat = 350
        let height: CGFloat = 76
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(
                NSRect(
                    x: frame.maxX - width - 18,
                    y: frame.maxY - height - 18,
                    width: width,
                    height: height
                ),
                display: true
            )
        } else {
            panel.setContentSize(NSSize(width: width, height: height))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }

        if let soundName = style.soundName {
            NSSound(named: NSSound.Name(soundName))?.play()
        }

        let dismiss = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6, execute: dismiss)
    }

    private func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel?.orderOut(nil)
                self?.panel = nil
            }
        }
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let contentRect = NSRect(x: 0, y: 0, width: 350, height: 76)
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: contentRect)
        self.panel = panel
        return panel
    }
}
