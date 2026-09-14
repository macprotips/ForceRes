import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp`. Registration only works from inside an `.app`
/// bundle; `swift run` produces a bare executable, so `isAvailable` guards the menu item.
enum LaunchAtLogin {
    /// `true` when the running executable lives inside an app bundle with an identifier.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// The login item's registration status; `.notRegistered` outside an app bundle.
    static var status: SMAppService.Status {
        guard isAvailable else { return .notRegistered }
        return SMAppService.mainApp.status
    }

    /// Registers or unregisters the app. Throws the `SMAppService` error on failure.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens System Settings › General › Login Items.
    static func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// How the "Launch at Login" toggle renders one `SMAppService.Status`.
struct LaunchAtLoginState: Equatable, Sendable {
    /// The toggle is on: registered, or registered and awaiting the user's approval.
    var isOn: Bool
    /// The user still has to approve the item in System Settings › Login Items.
    var requiresApproval: Bool

    init(status: SMAppService.Status) {
        isOn = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }
}
