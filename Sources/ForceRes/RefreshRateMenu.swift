import AppKit
import ForceResCore
import SwiftUI

/// The refresh-rate pop-up in the panel's bottom row, popping `PanelMenus.refreshMenu` for
/// whatever the display enumerates at the resolution in effect. Dimmed like the tiles, with no
/// menu to open, while disabled.
struct RefreshRateMenu: View {
    let state: RefreshControlState
    let select: (RefreshOption) -> Void

    static let developmentName = "refresh"

    var body: some View {
        PanelMenuButton(role: .popUpButton, accessibilityLabel: "Refresh rate", accessibilityValue: state.label,
                        accessibilityHelp: state.caption, toolTip: state.note ?? "Refresh rate",
                        isEnabled: state.isEnabled, developmentName: Self.developmentName,
                        menu: { PanelMenus.refreshMenu(state: state, select: select) }) { _ in
            label
        }
        .opacity(state.isEnabled ? 1 : PanelMetrics.disabledOpacity)
    }

    private var label: some View {
        HStack(spacing: 0) {
            Text("Refresh rate")
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            if let value = state.valueLabel {
                Text(value)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .padding(.leading, PanelMetrics.refreshPrefixToValue)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: PanelMetrics.refreshChevronSize, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .padding(.leading, PanelMetrics.refreshValueToChevron)
        }
        .font(.system(size: PanelMetrics.refreshLabelSize))
        .padding(PanelMetrics.controlInsets)
    }
}
