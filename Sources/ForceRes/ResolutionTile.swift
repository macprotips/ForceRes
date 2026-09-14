import ForceResCore
import SwiftUI

/// One preset tile: a `display` symbol over the short title. Selected tiles fill with the accent
/// colour; disabled tiles are dimmed and inert. Clicking the selected tile is a no-op.
struct ResolutionTile: View {
    let preset: ResolutionPreset
    let state: TileState
    /// Position in the row, 0 for the smallest preset. Only scales the glyph.
    let step: Int
    /// Reports hover so the panel can show the tile's note in its caption line.
    let hoverChanged: (Bool) -> Void
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let button = Button {
            guard !state.isSelected else { return }
            action()
        } label: {
            VStack(spacing: PanelMetrics.tileSymbolToLabel) {
                Image(systemName: "display")
                    .symbolRenderingMode(.monochrome)
                    .frame(height: PanelMetrics.tileSymbolSize(step: 3))
                    .font(.system(size: PanelMetrics.tileSymbolSize(step: step), weight: .regular))
                Text(preset.title)
                    .font(.system(size: PanelMetrics.tileLabelSize, weight: .semibold))
            }
            // The glyph box is fixed so a taller glyph never shifts the label off the baseline.
            .frame(width: PanelMetrics.tileWidth, height: PanelMetrics.tileHeight)
        }
        .buttonStyle(TileButtonStyle(isSelected: state.isSelected, isHovered: isHovered))
        .disabled(!state.isEnabled)
        .opacity(state.isEnabled ? 1 : PanelMetrics.disabledOpacity)
        .onHover { hovering in
            isHovered = hovering
            hoverChanged(hovering)
        }
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityValue(ifPresent: state.accessibilityValue)
        .accessibilityHint(ifPresent: state.accessibilityHint)
        .accessibilityAddTraits(state.isSelected ? .isSelected : [])
        if let note = state.note {
            button.help(note)
        } else {
            button
        }
    }
}

/// Fill, stroke and pressed feedback for `ResolutionTile`, in semantic colours.
struct TileButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelMetrics.tileCornerRadius, style: .continuous)
        configuration.label
            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Color(nsColor: .labelColor))
            .background(fill(pressed: configuration.isPressed), in: shape)
            .overlay {
                if !isSelected {
                    shape.strokeBorder(Color(nsColor: .separatorColor).opacity(PanelMetrics.tileStrokeOpacity), lineWidth: 1)
                }
            }
            .brightness(brightness(pressed: configuration.isPressed))
            .contentShape(shape)
    }

    private func fill(pressed: Bool) -> Color {
        if isSelected { return .accentColor }
        if pressed || isHovered { return Color(nsColor: .tertiarySystemFill) }
        return Color(nsColor: .quaternarySystemFill)
    }

    /// Selected: brighter on hover, darker when pressed. Unselected: darker when pressed only.
    private func brightness(pressed: Bool) -> Double {
        if isSelected {
            if pressed { return PanelMetrics.selectedPressedBrightness }
            return isHovered ? PanelMetrics.selectedHoverBrightness : 0
        }
        return pressed ? PanelMetrics.pressedBrightness : 0
    }
}

extension View {
    /// `accessibilityValue` only when there is one; an empty value would still be announced.
    @ViewBuilder
    func accessibilityValue(ifPresent value: String?) -> some View {
        if let value { accessibilityValue(value) } else { self }
    }

    /// `accessibilityHint` only when there is one.
    @ViewBuilder
    func accessibilityHint(ifPresent hint: String?) -> some View {
        if let hint { accessibilityHint(hint) } else { self }
    }
}
