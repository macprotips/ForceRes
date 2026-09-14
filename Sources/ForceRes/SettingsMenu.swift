import AppKit
import ForceResCore
import SwiftUI

/// The gear button in the panel header: pops `PanelMenus.settingsMenu` with everything that is
/// not a resolution tile (Default Resolution, the scaling toggle, Launch at Login, Revert while pending,
/// About, Quit).
struct SettingsMenu: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel
    /// The display the tile row currently controls; `nil` hides the "Default Resolution" entry.
    let display: DisplayInfo?
    /// Closes the popover (needed before the modal About alert takes over).
    let dismiss: () -> Void

    static let developmentName = "gear"

    var body: some View {
        PanelMenuButton(role: .menuButton, accessibilityLabel: "Settings", accessibilityValue: nil,
                        accessibilityHelp: nil, toolTip: "Settings", isEnabled: true,
                        developmentName: Self.developmentName,
                        menu: { PanelMenus.settingsMenu(model: model, display: display,
                                                        showAbout: { Self.showAbout(dismiss: dismiss) }) }) { hovered in
            Image(systemName: "gearshape")
                .font(.system(size: PanelMetrics.gearSymbolSize, weight: .regular))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .rotationEffect(.degrees(hovered ? PanelMetrics.gearHoverRotation : 0))
                .animation(reduceMotion ? nil : .easeOut(duration: PanelMetrics.gearRotationDuration),
                           value: hovered)
                .frame(width: PanelMetrics.gearHitSize, height: PanelMetrics.gearHitSize)
        }
    }

    /// Closes the panel (`dismiss`), then runs the modal About alert.
    static func showAbout(dismiss: () -> Void) {
        dismiss()
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development build"
        let build = info["CFBundleVersion"] as? String
        Alerts.runModal("Version \(version)\(build.map { " (\($0))" } ?? "")\n"
                        + "Forces a display to 720p, 1080p, 1440p, or 4K.")
    }
}
