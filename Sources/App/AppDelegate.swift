import AppKit
import Combine
import SwiftUI

// MARK: - App environment

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let paths: DriveStreamPaths
    let dependencyManager: DependencyManager
    let configService: RcloneConfigService
    let rcClient: RcloneRCClient
    let controller: MountController

    private init() {
        let paths = DriveStreamPaths.current
        try? paths.prepareFileSystem()
        self.paths = paths
        self.dependencyManager = DependencyManager(paths: paths)
        self.configService = RcloneConfigService(paths: paths)
        self.rcClient = RcloneRCClient()
        self.controller = MountController(
            dependencyManager: dependencyManager,
            configService: configService,
            rcClient: rcClient,
            paths: paths
        )
    }
}

// MARK: - Window management

@MainActor
final class DriveStreamWindowManager {
    private weak var controller: MountController?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var sidebarWindow: NSWindow?

    func configure(controller: MountController) {
        self.controller = controller
    }

    var isOnboardingVisible: Bool {
        onboardingWindow?.isVisible == true
    }

    func showSettings() {
        guard let controller else { return }
        if let window = settingsWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(controller: controller, onClose: { [weak self] in
            self?.settingsWindow?.close()
        })
        let window = makeWindow(
            title: "DriveStream Settings",
            contentSize: NSSize(width: 700, height: 620),
            rootView: AnyView(view)
        )
        settingsWindow = window
        present(window)
    }

    func showOnboarding() {
        guard let controller else { return }
        if let window = onboardingWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = OnboardingView(controller: controller, onClose: { [weak self] in
            self?.onboardingWindow?.close()
        })
        let window = makeWindow(
            title: "Set Up DriveStream",
            contentSize: NSSize(width: 700, height: 660),
            rootView: AnyView(view)
        )
        onboardingWindow = window
        present(window)
    }

    func showSidebarHelp() {
        guard let controller else { return }
        if let window = sidebarWindow, window.isVisible { present(window); return }
        let view = SidebarHelpView(controller: controller, onClose: { [weak self] in self?.sidebarWindow?.close() })
        let window = makeWindow(title: "DriveStream in Finder", contentSize: NSSize(width: 540, height: 440), rootView: AnyView(view))
        sidebarWindow = window
        present(window)
    }

    private func makeWindow(title: String, contentSize: NSSize, rootView: AnyView) -> NSWindow {
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = hostingController
        window.setContentSize(contentSize)
        window.minSize = contentSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = true
        window.center()
        window.collectionBehavior = [.moveToActiveSpace]
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment.shared
    private let windowManager = DriveStreamWindowManager()
    private var notificationObservers: [NSObjectProtocol] = []
    private var terminationRequested = false
    private var bootstrapTask: Task<Void, Never>?
    private var deviceMonitor: DeviceLifecycleMonitor?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        windowManager.configure(controller: environment.controller)
        FinderServicesProvider.shared.attach(controller: environment.controller)
        NSApp.servicesProvider = FinderServicesProvider.shared
        observeWindowRequests()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = environment.controller
        let monitor = DeviceLifecycleMonitor { [weak controller] event in controller?.handleDeviceLifecycle(event) }
        deviceMonitor = monitor
        monitor.start()
        Task {
            await FinderIntegrationService.updateServicesRegistry()
            await FinderIntegrationService.applyFirstRunSetupIfNeeded()
        }

        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.environment.controller.bootstrap()
            if !self.environment.controller.remoteIsConfigured && !self.windowManager.isOnboardingVisible {
                self.windowManager.showOnboarding()
            }
        }

        if !environment.controller.remoteIsConfigured {
            windowManager.showOnboarding()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationRequested { return .terminateLater }
        let controller = environment.controller
        guard controller.needsExitAssessment else {
            return .terminateNow
        }
        terminationRequested = true
        bootstrapTask?.cancel()
        Task { @MainActor in
            var safeToTerminate = await controller.shutdownForTermination()
            if !safeToTerminate && controller.exitBlockedByWrites {
                let alert = NSAlert()
                alert.messageText = controller.uploadSafety.title
                alert.informativeText = controller.uploadSafety.detail + "\n\nA completed Finder copy is not proof of a completed cloud upload. Keep the app running to finish writes. Quitting anyway retains cache files but may leave cloud data incomplete."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Keep Running")
                alert.addButton(withTitle: "Quit Anyway")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertSecondButtonReturn {
                    safeToTerminate = await controller.shutdownForTermination(allowPendingUploads: true)
                }
            }
            if safeToTerminate {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                self.terminationRequested = false
                NSApp.reply(toApplicationShouldTerminate: false)
                if !controller.exitBlockedByWrites {
                    let alert = NSAlert()
                    alert.messageText = "Close open files before quitting"
                    alert.informativeText = "DriveStream could not detach its volume. It will stay open so you can close apps using the drive and retry unmounting safely."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            windowManager.showSettings()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        bootstrapTask?.cancel()
        deviceMonitor?.stop()
        deviceMonitor = nil
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
        notificationObservers.removeAll()
    }

    // MARK: Notifications

    private func observeWindowRequests() {
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(forName: .driveStreamShowSettings, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.windowManager.showSettings()
                }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: .driveStreamShowSidebarHelp, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.windowManager.showSidebarHelp() }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: .driveStreamShowOnboarding, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.windowManager.showOnboarding()
                }
            }
        )
    }

    // MARK: Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu(title: "DriveStream")
        applicationItem.submenu = applicationMenu

        let aboutItem = NSMenuItem(
            title: "About DriveStream",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        applicationMenu.addItem(aboutItem)
        applicationMenu.addItem(.separator())

        let setupItem = NSMenuItem(
            title: "Setup Assistant…",
            action: #selector(showOnboardingFromMenu(_:)),
            keyEquivalent: ""
        )
        setupItem.target = self
        applicationMenu.addItem(setupItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)

        applicationMenu.addItem(.separator())

        let servicesMenuItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesMenuItem.submenu = servicesMenu
        applicationMenu.addItem(servicesMenuItem)
        NSApp.servicesMenu = servicesMenu

        applicationMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "Hide DriveStream",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        applicationMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        applicationMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        applicationMenu.addItem(showAllItem)

        applicationMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit DriveStream",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        applicationMenu.addItem(quitItem)

        // Edit menu so text fields in the setup/settings windows support the
        // standard clipboard and undo shortcuts even though this is a menu-bar app.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettingsFromMenu(_ sender: Any?) {
        windowManager.showSettings()
    }

    @objc private func showOnboardingFromMenu(_ sender: Any?) {
        windowManager.showOnboarding()
    }
}
