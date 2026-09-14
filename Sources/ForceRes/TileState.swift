import ForceResCore

/// Everything a `ResolutionTile` needs to draw one preset, derived from pure inputs so the
/// enabled flag, note and accessibility strings can be unit tested without SwiftUI.
struct TileState: Equatable, Sendable {
    /// Shown on the preset tiles while a change awaits Keep/Revert.
    static let pendingNote = "Keep or revert the current change first"
    /// Shown on the preset tiles while a change is being applied.
    static let busyNote = "Applying a change…"
    /// Shown when the preset needs a virtual display and the private route is missing.
    static let virtualUnsupportedNote = "Not available on this Mac"

    /// The preset is the one currently in effect on the display.
    var isSelected: Bool
    /// `false` dims the tile and makes it non-interactive.
    var isEnabled: Bool
    /// Why the tile is disabled, the virtual-display caveat, or the scaling fallback. `nil` for a
    /// plain native tile.
    var note: String?
    /// "1080p, 1920 by 1080".
    var accessibilityLabel: String
    /// Read after the label: the unavailability reason or the virtual/scaling caveat.
    var accessibilityValue: String?
    /// What activating the tile does; `nil` when it does nothing (selected or disabled).
    var accessibilityHint: String?

    /// - Parameters:
    ///   - preset: the tile's preset.
    ///   - availability: `AppModel.availability(of:for:)` for the display the row controls.
    ///   - isSelected: `AppModel.currentPreset(for:) == preset`.
    ///   - isVirtualSupported: `AppModel.isVirtualSupported`.
    ///   - scaling: the current scaling preference, used to word the fallback note.
    ///   - isConfirmationPending: `AppModel.pendingConfirmation != nil`; disables every tile.
    ///   - isBusy: `AppModel.isBusy`; disables every tile.
    init(preset: ResolutionPreset, availability: PresetAvailability, isSelected: Bool,
         isVirtualSupported: Bool, scaling: ScalingPreference,
         isConfirmationPending: Bool = false, isBusy: Bool = false) {
        let size = preset.pixelSize
        self.isSelected = isSelected
        accessibilityLabel = "\(preset.title), \(size.width) by \(size.height)"
        switch availability {
        case .available(_, let exact):
            isEnabled = true
            if !exact {
                note = scaling == .hiDPI
                    ? "No HiDPI variant on this display; uses the 1x mode"
                    : "No 1x variant on this display; uses the HiDPI mode"
            }
            accessibilityValue = note
        case .needsVirtualDisplay(let plan):
            var caveat = "Via virtual display, \(Units.hertz(60))"
            if plan.letterboxed { caveat += ", letterboxed" }
            if isVirtualSupported {
                isEnabled = true
                note = caveat
                accessibilityValue = caveat
            } else {
                isEnabled = false
                note = Self.virtualUnsupportedNote
                accessibilityValue = "Not available on this display: \(Self.virtualUnsupportedNote)"
            }
        case .unavailable(let reason):
            isEnabled = false
            note = reason.message
            accessibilityValue = "Not available on this display: \(reason.message)"
        }
        if isEnabled, isConfirmationPending || isBusy {
            isEnabled = false
            note = isConfirmationPending ? Self.pendingNote : Self.busyNote
            accessibilityValue = note
        }
        if isEnabled && !isSelected {
            accessibilityHint = "Switches the display to \(preset.detailedTitle)"
        }
    }

    /// The caption under the tile row: the hovered tile's note, else the refresh-rate fallback
    /// note, else the first disabled tile's note, else empty.
    static func caption(hovered: TileState?, refreshNote: String? = nil, states: [TileState]) -> String {
        if let note = hovered?.note { return note }
        if let refreshNote { return refreshNote }
        return states.first { !$0.isEnabled }?.note ?? ""
    }
}
