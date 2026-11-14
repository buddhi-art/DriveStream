import SwiftUI

@main
struct DriveStreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppEnvironment.shared.controller

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(controller: controller)
        } label: {
            Image(systemName: controller.menuBarSymbolName)
                .accessibilityLabel("DriveStream")
                .help("DriveStream — Google Drive in Finder")
        }
        .menuBarExtraStyle(.window)
    }
}
