import ForceResCore

/// Builds the human-readable strings used by the menu and the confirmation panel.
enum ChangeDescription {
    /// "Odyssey G80SD → 1080p (1920 × 1080) HiDPI at 240 Hertz",
    /// "Odyssey G80SD → Default Resolution (2560 × 1440) HiDPI at 240 Hertz".
    static func nativeMode(display: DisplayInfo, preset: ResolutionPreset?, mode: DisplayModeInfo) -> String {
        let target = preset?.detailedTitle ?? "\(AppModel.defaultResolutionTitle) (\(mode.width) × \(mode.height))"
        return "\(display.name) → \(target) \(mode.isHiDPI ? "HiDPI" : "1x") at \(refresh(mode.refreshRate))"
    }

    /// "Odyssey G80SD → 1440p at 120 Hertz", "Odyssey G80SD → 1440p, Variable (48–240 Hertz)",
    /// "MacBook Pro → Default Resolution, ProMotion"; falls back to `nativeMode` for an unclassified 0 Hz entry.
    static func refreshChange(display: DisplayInfo, preset: ResolutionPreset?, mode: DisplayModeInfo,
                              isProMotion: Bool) -> String {
        guard mode.isAdaptiveRefresh == true || mode.roundedRefreshRate > 0 else {
            return nativeMode(display: display, preset: preset, mode: mode)
        }
        let option = ModeSelector.refreshOption(of: mode, range: display.variableRefreshRange)
        let target = preset?.title ?? AppModel.defaultResolutionTitle
        let label = RefreshControlState.label(for: option, isProMotion: isProMotion)
        switch option {
        case .fixed: return "\(display.name) → \(target) at \(label)"
        case .variable: return "\(display.name) → \(target), \(label)"
        }
    }

    /// "MacBook Air → 1080p (1920 × 1080) virtual, 60 Hertz, letterboxed".
    static func virtualMirror(display: DisplayInfo, preset: ResolutionPreset, plan: VirtualDisplayPlan) -> String {
        "\(display.name) → \(preset.detailedTitle) \(virtualSuffix(plan))"
    }

    /// "virtual, 60 Hertz[, letterboxed][, beyond panel]" — shared by the menu label and the panel.
    static func virtualSuffix(_ plan: VirtualDisplayPlan) -> String {
        var text = "virtual, \(Units.hertz(60))"
        if plan.letterboxed { text += ", letterboxed" }
        if plan.exceedsPanel { text += ", beyond panel" }
        return text
    }

    /// "240 Hertz" (59.94 reads "60 Hertz"), or "adaptive refresh" for a 0 Hz (ProMotion) entry.
    static func refresh(_ rate: Double) -> String {
        guard rate > 0 else { return "adaptive refresh" }
        return Units.hertz(Int(rate.rounded()))
    }
}
