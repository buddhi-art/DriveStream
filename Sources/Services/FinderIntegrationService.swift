import AppKit
import Foundation

enum FinderIntegrationService {
    private static let firstRunKey = "DriveStream.finderIntegration.v1"

    /// Applies the one-time defaults that prevent Finder from scattering metadata
    /// files over the cloud remote and enable the volume in Finder's sidebar/Desktop.
    static func applyFirstRunSetupIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: firstRunKey) else { return }
        // Equivalent shell command:
        // defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
        await writeDefault(domain: "com.apple.desktopservices", key: "DSDontWriteNetworkStores", value: "true")
        await applyFinderPreferences(showDesktopIcons: true)
        defaults.set(true, forKey: firstRunKey)
    }

    static func applyFinderPreferences(showDesktopIcons: Bool) async {
        await writeDefault(domain: "com.apple.finder", key: "ShowSidebar", value: "true")
        await writeDefault(domain: "com.apple.finder", key: "ShowStatusBar", value: "true")
        await writeDefault(domain: "com.apple.finder", key: "ShowPathbar", value: "true")
        let value = showDesktopIcons ? "true" : "false"
        for key in [
            "ShowHardDrivesOnDesktop",
            "ShowExternalHardDrivesOnDesktop",
            "ShowRemovableMediaOnDesktop",
            "ShowMountedServersOnDesktop"
        ] {
            await writeDefault(domain: "com.apple.finder", key: key, value: value)
        }
    }

    static func restartFinder() async {
        _ = try? await CommandRunner.run(executable: "/usr/bin/killall", arguments: ["Finder"], timeout: 15)
    }

    @MainActor
    static func updateServicesRegistry() async {
        NSUpdateDynamicServices()
        _ = try? await CommandRunner.run(
            executable: "/System/Library/CoreServices/pbs",
            arguments: ["-update"],
            timeout: 25
        )
    }

    private static func writeDefault(domain: String, key: String, value: String) async {
        _ = try? await CommandRunner.run(
            executable: "/usr/bin/defaults",
            arguments: ["write", domain, key, "-bool", value],
            timeout: 10
        )
    }
}
