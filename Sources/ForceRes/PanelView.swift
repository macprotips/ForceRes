import ForceResCore
import SwiftUI

/// Contents of the status item popover: header, an optional display picker, the preset tile row,
/// and a bottom row with the refresh control and a caption. Reads the model through
/// `@Observable` tracking, so the selected tile follows external mode changes.
struct PanelView: View {
    let model: AppModel
    /// Closes the popover.
    let dismiss: () -> Void

    @State private var hoveredPreset: ResolutionPreset?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Picker labels longer than this switch the picker to the pull-down style.
    nonisolated static let maxSegmentedNameLength = 14
    /// More displays than this switch the picker to the pull-down style.
    nonisolated static let maxSegmentedDisplays = 3

    private var display: DisplayInfo? {
        let displays = model.displays
        return displays.first { $0.id == model.selectedDisplayID }
            ?? displays.first(where: \.isMain)
            ?? displays.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.displays.count > 1 {
                displayPicker
                    .padding(.top, PanelMetrics.headerToPicker)
            }
            tileRow
                .padding(.top, PanelMetrics.headerToTiles)
            bottomRow
                .padding(.top, PanelMetrics.tilesToBottomRow)
        }
        .frame(width: PanelMetrics.contentWidth)
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.top, PanelMetrics.topPadding)
        .padding(.bottom, PanelMetrics.bottomPadding)
    }

    /// What the display is on right now, which is more use than repeating what the app does. Names
    /// the display when it is the only one; with several, the picker below already names them.
    private var subtitle: String {
        guard let display, let mode = display.currentMode else { return "Set your display resolution" }
        let size = "\(mode.width) × \(mode.height)"
        return model.displays.count > 1 ? size : "\(display.name) · \(size)"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: PanelMetrics.titleToSubtitle) {
                Text("ForceRes")
                    .font(.system(size: PanelMetrics.titleSize, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                Text(subtitle)
                    .font(.system(size: PanelMetrics.subtitleSize))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(subtitle)
            }
            Spacer(minLength: 0)
            // Pulled out by the hit target's overhang so the glyph, not the invisible button,
            // lines up with the tile row's right edge, and centred on the title's capitals.
            SettingsMenu(model: model, display: display, dismiss: dismiss)
                .padding(.trailing, -PanelMetrics.gearOverhang)
                .padding(.top, PanelMetrics.gearTopOffset)
        }
    }

    /// "Built-in Display" for the built-in panel, the display's name otherwise.
    nonisolated static func pickerTitle(for display: DisplayInfo) -> String {
        display.isBuiltIn ? "Built-in Display" : display.name
    }

    /// Segmented while every label is short and there are few displays; a pull-down otherwise.
    nonisolated static func usesMenuPicker(titles: [String]) -> Bool {
        titles.count > maxSegmentedDisplays || titles.contains { $0.count > maxSegmentedNameLength }
    }

    @ViewBuilder
    private var displayPicker: some View {
        let titles = model.displays.map(Self.pickerTitle(for:))
        let picker = Picker("Display", selection: Binding(
            get: { display?.id ?? "" },
            set: { model.selectedDisplayID = $0 })) {
            ForEach(model.displays) { display in
                Text(Self.pickerTitle(for: display)).tag(display.id)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        if Self.usesMenuPicker(titles: titles) {
            picker.pickerStyle(.menu).fixedSize()
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private var tileStates: [(preset: ResolutionPreset, state: TileState)] {
        guard let display else { return [] }
        return model.presets(for: display).map { ($0, model.tileState($0, for: display)) }
    }

    @ViewBuilder
    private var tileRow: some View {
        if let display {
            let current = model.currentPreset(for: display)
            let busy = model.isBusy
            HStack(spacing: PanelMetrics.tileGap) {
                ForEach(Array(tileStates.enumerated()), id: \.element.preset) { step, entry in
                    ResolutionTile(preset: entry.preset, state: entry.state, step: step,
                                   hoverChanged: { hovering in
                        if hovering {
                            hoveredPreset = entry.preset
                        } else if hoveredPreset == entry.preset {
                            hoveredPreset = nil
                        }
                    }) {
                        model.select(preset: entry.preset, for: display)
                    }
                }
            }
            .opacity(busy ? PanelMetrics.busyOpacity : 1)
            .overlay {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Applying")
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: PanelMetrics.selectionAnimationDuration),
                       value: current)
        } else {
            Text("No displays found")
                .font(.system(size: PanelMetrics.subtitleSize))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(maxWidth: .infinity, minHeight: PanelMetrics.tileHeight)
        }
    }

    /// The refresh-rate control on the left and the caption on the right, one fixed-height row so
    /// the panel never changes height. The control is pulled out by its own inset so its text,
    /// not its hover fill, lines up with the tile row's left edge.
    private var bottomRow: some View {
        let refreshState = display.map { model.refreshControlState(for: $0) }
        return HStack(spacing: PanelMetrics.refreshToCaption) {
            if let display, let refreshState {
                RefreshRateMenu(state: refreshState) { option in
                    model.select(refresh: option.preference, for: display)
                }
                .padding(.leading, -PanelMetrics.controlInsets.leading)
            }
            caption(refreshState: refreshState)
        }
        .frame(height: PanelMetrics.bottomRowHeight)
    }

    /// Trailing-aligned secondary text; empty most of the time. Long notes truncate and repeat
    /// in full as a tooltip. Hidden from VoiceOver: every string it can show is already exposed
    /// on the control it describes (the tiles' values, the refresh control's hint).
    private func caption(refreshState: RefreshControlState?) -> some View {
        let states = tileStates
        let hovered = states.first { $0.preset == hoveredPreset }?.state
        let text = TileState.caption(hovered: hovered, refreshNote: refreshState?.caption, states: states.map(\.state))
        return Text(text)
            .font(.system(size: PanelMetrics.captionSize))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(text)
            .accessibilityHidden(true)
    }
}
