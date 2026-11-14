import Combine
import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    init() { refresh() }

    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
        requiresApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func setEnabled(_ requested: Bool) {
        do {
            if requested { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            errorMessage = nil
        } catch {
            errorMessage = "Login-item registration failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
}
