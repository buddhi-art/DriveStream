import Foundation

/// Shared event names live outside AppDelegate so core services and hostless
/// native tests do not need to instantiate the application or its real account.
extension Notification.Name {
    static let driveStreamShowSettings = Notification.Name("DriveStream.showSettings")
    static let driveStreamShowOnboarding = Notification.Name("DriveStream.showOnboarding")
    static let driveStreamShowSidebarHelp = Notification.Name("DriveStream.showSidebarHelp")
}
