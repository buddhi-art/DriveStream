import AppKit
import SwiftUI

/// Finder owns Locations and Favorites. Do not edit private sidebar databases or
/// claim a detached directory is a mounted local disk. This one-time native guide
/// gives users a persistent supported shortcut while the app preserves mounts.
struct SidebarHelpView: View {
    @ObservedObject var controller: MountController
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Keep DriveStream in Finder", systemImage: "sidebar.left")
                .font(.title2.weight(.semibold))
            Text("While mounted, the drive appears under Locations when Finder's connected-server or external-volume sidebar items are enabled. DriveStream keeps a healthy mount attached when the network disappears or the Mac sleeps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("A shortcut that stays even when the app is closed")
                    .font(.headline)
                Label("Open the mount folder below.", systemImage: "1.circle")
                Label("Drag this folder into Finder's Favorites section once.", systemImage: "2.circle")
                Label("Enable launch at login and automatic mounting in Settings.", systemImage: "3.circle")
            }
            .font(.callout)
            Text(controller.mountPath)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Locations represents attached volumes; Favorites represents saved shortcuts. When detached, this folder must remain empty. Do not store ordinary local files in it or mistake it for available cloud data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Mount Folder") { controller.openMountFolderForSidebar() }
                    .buttonStyle(.borderedProminent)
                Button("Open Settings") { controller.presentSettings() }
                Spacer()
                Button("Done") {
                    if let onClose { onClose() }
                    else { NSApp.keyWindow?.close() }
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
