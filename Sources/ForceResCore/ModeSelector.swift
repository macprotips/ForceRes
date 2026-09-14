import Foundation

/// Pure mode-selection rules. Everything here is deterministic over recorded mode lists so it can
/// be unit tested without a display attached; the display layer feeds it `DisplayInfo` values.
public enum ModeSelector: Sendable {
    /// The ratio by which two aspect ratios may differ before a virtual display is letterboxed.
    public static let letterboxTolerance: Double = 0.01

    // MARK: Selection

    /// Picks the best GUI-usable mode for `preset` honouring `scaling`, falling back to the other
    /// scaling variant when the preferred one does not exist. `select` returns the same pick with
    /// the scaling and refresh outcomes attached.
    ///
    /// Candidates are limited to `isUsableForDesktopGUI` modes that are neither interlaced nor
    /// stretched. Within the chosen variant, `refresh` narrows the candidates (see
    /// `RefreshPreference`); the winner then has the highest refresh rate (equal after rounding to
    /// whole Hz; 0 Hz means adaptive and ranks equal to the maximum), then the safe flag, then
    /// native timing, then `isAdaptiveRefresh == true` (the twin macOS itself picks), then the
    /// earliest entry in `preferredModeIDs`, then the lowest `id`.
    ///
    /// - Parameter preferredModeIDs: mode ids to prefer, most preferred first, among otherwise
    ///   equal candidates. Displays list byte-identical duplicate modes under different ids
    ///   (docs/RESEARCH.md addendum); the user's own ids keep the pick on the entry in use.
    public static func selectMode(for preset: ResolutionPreset, scaling: ScalingPreference,
                                  in modes: [DisplayModeInfo],
                                  preferredModeIDs: [Int32] = [],
                                  refresh: RefreshPreference = .highest) -> DisplayModeInfo? {
        select(for: preset, scaling: scaling, in: modes, preferredModeIDs: preferredModeIDs,
               refresh: refresh)?.mode
    }

    /// `selectMode` with the outcomes: whether the requested scaling variant existed and whether
    /// `refresh` was honoured (`.fellBackToHighest` when no mode in the chosen variant matched a
    /// `.fixed` or `.variable` request, in which case the `.highest` rule picked the mode;
    /// `.unverified` when the variant has an unclassified entry, see `RefreshOutcome`).
    public static func select(for preset: ResolutionPreset, scaling: ScalingPreference,
                              in modes: [DisplayModeInfo],
                              preferredModeIDs: [Int32] = [],
                              refresh: RefreshPreference = .highest) -> ModeSelection? {
        let usable = modes.filter(isCandidate)
        let fallback: ScalingPreference = scaling == .hiDPI ? .lowResolution : .hiDPI
        for (variant, exact) in [(scaling, true), (fallback, false)] {
            let family = usable.filter { matches($0, preset: preset, variant: variant) }
            if let picked = pick(from: family, refresh: refresh, preferredModeIDs: preferredModeIDs) {
                return ModeSelection(mode: picked.mode, exactScaling: exact, refreshOutcome: picked.outcome)
            }
        }
        return nil
    }

    /// The `refresh` pick within the family of `anchor` (same point and pixel size), the unit the
    /// refresh-rate control operates on: `select(for:scaling:…)` picks by preset, this covers the
    /// "Native" case where the family is anchored on a mode. Candidates are the family's
    /// GUI-usable, non-interlaced, non-stretched modes; the ranking, `preferredModeIDs` and the
    /// `.fellBackToHighest`/`.unverified` outcomes are exactly those of `select(for:scaling:…)`.
    /// `exactScaling` is always `true`. `nil` when the family has no candidate.
    public static func select(inFamilyOf anchor: DisplayModeInfo, in modes: [DisplayModeInfo],
                              preferredModeIDs: [Int32] = [],
                              refresh: RefreshPreference) -> ModeSelection? {
        guard let picked = pick(from: family(of: anchor, in: modes), refresh: refresh,
                                preferredModeIDs: preferredModeIDs) else { return nil }
        return ModeSelection(mode: picked.mode, exactScaling: true, refreshOutcome: picked.outcome)
    }

    /// Whether `current` already delivers what `target` was selected for, so the app can avoid
    /// re-applying a mode (fixed/variable twins never churn). `current` must be a candidate in
    /// `target.mode`'s family (same point and pixel size, GUI-usable); the same id is always
    /// satisfied. Then `refresh` decides:
    /// - `.highest`: `refreshRatesEqual(current.refreshRate, target.mode.refreshRate)`, where a
    ///   0 Hz (adaptive) rate on either side counts as the maximum and therefore equal;
    /// - `.fixed(hertz)`: `current.roundedRefreshRate == hertz` and `current.isAdaptiveRefresh != true`;
    /// - `.variable`: `current.isAdaptiveRefresh == true`.
    ///
    /// When `target.refreshOutcome` is not `.exact` the preference was not honoured (it fell back
    /// to highest, or could not be verified), so the `.highest` rule applies instead; otherwise a
    /// `.fixed(144)` request on a display without 144 Hz would never be satisfied.
    public static func isSatisfied(current: DisplayModeInfo, by target: ModeSelection,
                                   refresh: RefreshPreference) -> Bool {
        guard isCandidate(current), inSameFamily(current, target.mode) else { return false }
        if current.id == target.mode.id { return true }
        let effective: RefreshPreference = target.refreshOutcome == .exact ? refresh : .highest
        switch effective {
        case .highest:
            return current.refreshRate == 0 || target.mode.refreshRate == 0
                || refreshRatesEqual(current.refreshRate, target.mode.refreshRate)
        case .fixed(let hertz):
            return current.roundedRefreshRate == hertz && current.isAdaptiveRefresh != true
        case .variable:
            return current.isAdaptiveRefresh == true
        }
    }

    /// Full availability verdict for `preset` on `display`, including the fallback plan when no
    /// native mode exists. `preferredModeIDs` and `refresh` apply exactly as in `selectMode`; use
    /// `select` when the refresh outcome matters.
    public static func availability(of preset: ResolutionPreset, scaling: ScalingPreference,
                                    for display: DisplayInfo,
                                    preferredModeIDs: [Int32] = [],
                                    refresh: RefreshPreference = .highest) -> PresetAvailability {
        if display.modes.isEmpty {
            return .unavailable(.noModes)
        }
        if let picked = select(for: preset, scaling: scaling, in: display.modes,
                               preferredModeIDs: preferredModeIDs, refresh: refresh) {
            return .available(picked.mode, exactScaling: picked.exactScaling)
        }
        let anySizeMatch = display.modes.contains { matches($0, preset: preset, variant: .hiDPI)
            || matches($0, preset: preset, variant: .lowResolution) }
        if anySizeMatch {
            return .unavailable(.onlyUnsafeModes)
        }
        let plan = virtualDisplayPlan(for: preset, scaling: scaling,
                                      nativePixelSize: display.nativePixelSize)
        // A panel cannot show more pixels than it has. Mirroring a larger virtual display onto it
        // only downscales, so offer nothing rather than something that looks worse.
        if plan.exceedsPanel, display.nativePixelSize.width > 0, display.nativePixelSize.height > 0 {
            return .unavailable(.exceedsPanel(panel: display.nativePixelSize))
        }
        return .needsVirtualDisplay(plan)
    }

    /// The plan used when a preset has no native mode on a panel of `nativePixelSize`.
    public static func virtualDisplayPlan(for preset: ResolutionPreset, scaling: ScalingPreference,
                                          nativePixelSize: PixelSize) -> VirtualDisplayPlan {
        let target = preset.pixelSize
        let letterboxed: Bool
        if nativePixelSize.width > 0, nativePixelSize.height > 0 {
            let native = nativePixelSize.aspectRatio
            letterboxed = abs(target.aspectRatio - native) / native > letterboxTolerance
        } else {
            letterboxed = false
        }
        let exceeds = target.width > nativePixelSize.width || target.height > nativePixelSize.height
        return VirtualDisplayPlan(pixelSize: target, hiDPI: scaling == .hiDPI,
                                  letterboxed: letterboxed, exceedsPanel: exceeds)
    }

    /// The mode the "Native" menu entry restores: the display's recorded original mode when it
    /// is still listed and usable for the desktop GUI, otherwise `defaultMode(in:)`.
    ///
    /// The default-flagged mode is only a fallback: it need not be the mode the user runs
    /// (docs/RESEARCH.md addendum).
    public static func restoreMode(in modes: [DisplayModeInfo], originalModeID: Int32?) -> DisplayModeInfo? {
        if let originalModeID,
           let original = modes.first(where: { $0.id == originalModeID }),
           original.isUsableForDesktopGUI {
            return original
        }
        return defaultMode(in: modes)
    }

    /// The display's default mode, the fallback for `restoreMode` when no original is recorded.
    ///
    /// Prefers the mode carrying `IOFlags.default`. Otherwise the best safe HiDPI mode with native
    /// timing, then the best safe mode with native timing at any scaling, then the best safe mode
    /// with the largest pixel size. "Best" applies the refresh/safe/native/id ranking.
    public static func defaultMode(in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        let flaggedDefault = modes.filter { $0.ioFlags & DisplayModeInfo.IOFlags.default != 0 }
        if let mode = best(of: flaggedDefault) { return mode }

        let safe = modes.filter { $0.isUsableForDesktopGUI && $0.isSafe && !$0.isInterlaced && !$0.isStretched }
        if let mode = best(of: safe.filter { $0.isHiDPI && $0.isNativeTiming }) { return mode }
        if let mode = best(of: safe.filter { $0.isNativeTiming }) { return mode }

        guard let largestArea = safe.map(pixelArea).max() else { return nil }
        return best(of: safe.filter { pixelArea($0) == largestArea })
    }

    /// Which preset the display's current mode corresponds to, if any, so the menu can show a
    /// checkmark. `exact` is `true` when the current variant (HiDPI or 1x) is the one `scaling`
    /// asks for.
    public static func currentPreset(for display: DisplayInfo,
                                     scaling: ScalingPreference) -> (preset: ResolutionPreset, exact: Bool)? {
        guard let current = display.currentMode else { return nil }
        for preset in ResolutionPreset.allCases {
            if matches(current, preset: preset, variant: .hiDPI) {
                return (preset, scaling == .hiDPI)
            }
            if matches(current, preset: preset, variant: .lowResolution) {
                return (preset, scaling == .lowResolution)
            }
        }
        return nil
    }

    // MARK: Refresh rate

    /// The refresh-rate options a display enumerates for one resolution, highest first, with
    /// `.variable` prepended only when a candidate is classified adaptive
    /// (`isAdaptiveRefresh == true`; unclassified entries never add it).
    ///
    /// With a `preset`, the candidates are its GUI-usable, non-interlaced, non-stretched modes in
    /// the scaling variant `select` would use (the requested one, else the other). With `nil`,
    /// they are the family of `display.currentMode` (same point and pixel size, the "Native"
    /// case). Rates are whole Hz, deduplicated; 0 Hz (adaptive) entries contribute no fixed
    /// option. Empty when the current mode is unknown or nothing matches.
    public static func availableRefreshOptions(for preset: ResolutionPreset?, scaling: ScalingPreference,
                                               in display: DisplayInfo) -> [RefreshOption] {
        let family: [DisplayModeInfo]
        if let preset {
            let usable = display.modes.filter(isCandidate)
            let fallback: ScalingPreference = scaling == .hiDPI ? .lowResolution : .hiDPI
            let exact = usable.filter { matches($0, preset: preset, variant: scaling) }
            family = exact.isEmpty ? usable.filter { matches($0, preset: preset, variant: fallback) } : exact
        } else {
            guard let current = display.currentMode else { return [] }
            family = self.family(of: current, in: display.modes)
        }
        let rates = Set(family.map(\.roundedRefreshRate)).filter { $0 > 0 }.sorted(by: >)
        var options = rates.map { RefreshOption.fixed(hertz: $0) }
        if family.contains(where: { $0.isAdaptiveRefresh == true }) {
            options.insert(variableOption(range: display.variableRefreshRange), at: 0)
        }
        return options
    }

    /// The option matching the display's current mode (`refreshOption(of:range:)`), or `nil`
    /// when it cannot be named: the current mode is unknown; it reports 0 Hz without being
    /// classified adaptive; or it is unclassified (`isAdaptiveRefresh == nil`) while a twin exists
    /// in its family (same point and pixel size and rounded rate under another id), since nothing
    /// public tells the fixed twin from the variable one (docs/RESEARCH.md section 11).
    public static func currentRefreshOption(for display: DisplayInfo) -> RefreshOption? {
        guard let current = display.currentMode else { return nil }
        if current.isAdaptiveRefresh == nil {
            let hasTwin = family(of: current, in: display.modes).contains {
                $0.id != current.id && $0.roundedRefreshRate == current.roundedRefreshRate
            }
            if hasTwin { return nil }
        }
        guard current.isAdaptiveRefresh == true || current.roundedRefreshRate > 0 else { return nil }
        return refreshOption(of: current, range: display.variableRefreshRange)
    }

    /// The option `mode` delivers: `.variable` (carrying `range`) when it is classified adaptive,
    /// otherwise `.fixed` at its whole-Hz rate. An unclassified 0 Hz entry therefore yields
    /// `.fixed(hertz: 0)`; use `currentRefreshOption(for:)` when "unknown" must stay `nil`.
    public static func refreshOption(of mode: DisplayModeInfo, range: ClosedRange<Double>?) -> RefreshOption {
        if mode.isAdaptiveRefresh == true { return variableOption(range: range) }
        return .fixed(hertz: mode.roundedRefreshRate)
    }

    private static func variableOption(range: ClosedRange<Double>?) -> RefreshOption {
        .variable(minHertz: range?.lowerBound, maxHertz: range?.upperBound)
    }

    // MARK: Helpers

    /// `true` when two refresh rates round to the same whole Hz (59.94 Hz equals 60 Hz).
    public static func refreshRatesEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.rounded() == rhs.rounded()
    }

    /// The panel's native pixel size as documented on `DisplayInfo.nativePixelSize`: the pixel
    /// size of a mode carrying `IOFlags.native` (the largest if several), otherwise the largest 1x
    /// mode, otherwise the largest pixel size of any mode. Empty input yields 0x0.
    public static func nativePixelSize(from modes: [DisplayModeInfo]) -> PixelSize {
        let nativeFlagged = modes.filter(\.isNativeTiming)
        if let mode = nativeFlagged.max(by: { pixelArea($0) < pixelArea($1) }) { return mode.pixelSize }
        let oneX = modes.filter { !$0.isHiDPI }
        if let mode = oneX.max(by: { pixelArea($0) < pixelArea($1) }) { return mode.pixelSize }
        if let mode = modes.max(by: { pixelArea($0) < pixelArea($1) }) { return mode.pixelSize }
        return PixelSize(width: 0, height: 0)
    }

    /// `true` when `mode` is the given scaling variant of `preset`, ignoring flags.
    public static func matches(_ mode: DisplayModeInfo, preset: ResolutionPreset,
                               variant: ScalingPreference) -> Bool {
        let target = preset.pixelSize
        switch variant {
        case .hiDPI:
            return mode.pointSize == target
                && mode.pixelSize == PixelSize(width: target.width * 2, height: target.height * 2)
        case .lowResolution:
            return mode.pixelSize == target && !mode.isHiDPI
        }
    }

    // MARK: Families

    /// A mode the selector may pick: usable for the desktop GUI, neither interlaced nor stretched.
    static func isCandidate(_ mode: DisplayModeInfo) -> Bool {
        mode.isUsableForDesktopGUI && !mode.isInterlaced && !mode.isStretched
    }

    /// `true` when both modes have the same point and pixel size (one refresh-rate family).
    static func inSameFamily(_ lhs: DisplayModeInfo, _ rhs: DisplayModeInfo) -> Bool {
        lhs.pointSize == rhs.pointSize && lhs.pixelSize == rhs.pixelSize
    }

    /// The candidates (`isCandidate`) in `anchor`'s family, in the order of `modes`.
    static func family(of anchor: DisplayModeInfo, in modes: [DisplayModeInfo]) -> [DisplayModeInfo] {
        modes.filter { isCandidate($0) && inSameFamily($0, anchor) }
    }

    // MARK: Ranking

    /// The best-ranked mode of `candidates`, or nil when empty.
    ///
    /// Ranking: highest effective refresh rate (0 Hz counts as the maximum among the candidates),
    /// then `isSafe`, then `isNativeTiming`, then `isAdaptiveRefresh == true`, then the earliest
    /// position in `preferredModeIDs` (ids not listed rank last), then lowest `id`. Colour depth
    /// is deliberately not a tie-break: CoreGraphics reports a single depth for every mode
    /// (docs/RESEARCH.md section 1), so it could never separate two candidates.
    static func best(of candidates: [DisplayModeInfo], preferredModeIDs: [Int32] = []) -> DisplayModeInfo? {
        let maxRate = candidates.map(\.refreshRate).max() ?? 0
        func effectiveRate(_ mode: DisplayModeInfo) -> Double {
            mode.refreshRate == 0 ? maxRate : mode.refreshRate
        }
        func preferenceRank(_ mode: DisplayModeInfo) -> Int {
            preferredModeIDs.firstIndex(of: mode.id) ?? preferredModeIDs.count
        }
        func outranks(_ lhs: DisplayModeInfo, _ rhs: DisplayModeInfo) -> Bool {
            let lRate = effectiveRate(lhs), rRate = effectiveRate(rhs)
            if !refreshRatesEqual(lRate, rRate) { return lRate > rRate }
            if lhs.isSafe != rhs.isSafe { return lhs.isSafe }
            if lhs.isNativeTiming != rhs.isNativeTiming { return lhs.isNativeTiming }
            let lVariable = lhs.isAdaptiveRefresh == true, rVariable = rhs.isAdaptiveRefresh == true
            if lVariable != rVariable { return lVariable }
            let lRank = preferenceRank(lhs), rRank = preferenceRank(rhs)
            if lRank != rRank { return lRank < rRank }
            return lhs.id < rhs.id
        }
        var winner: DisplayModeInfo?
        for candidate in candidates {
            if let current = winner, !outranks(candidate, current) { continue }
            winner = candidate
        }
        return winner
    }

    /// Applies `refresh` to one family: `.fixed` keeps the non-adaptive modes at that whole-Hz
    /// rate, `.variable` keeps the adaptive entries; when the narrowed set is empty the whole
    /// family is ranked instead and the outcome says so. A `.fixed`/`.variable` request on a
    /// family with any unclassified entry (`isAdaptiveRefresh == nil`) still picks by the same
    /// rules but reports `.unverified`, because a twin pair cannot be told apart without the
    /// classifier.
    private static func pick(from family: [DisplayModeInfo], refresh: RefreshPreference,
                             preferredModeIDs: [Int32]) -> (mode: DisplayModeInfo, outcome: RefreshOutcome)? {
        let narrowed: [DisplayModeInfo]
        switch refresh {
        case .highest:
            narrowed = family
        case .fixed(let hertz):
            narrowed = family.filter { $0.roundedRefreshRate == hertz && $0.isAdaptiveRefresh != true }
        case .variable:
            narrowed = family.filter { $0.isAdaptiveRefresh == true }
        }
        let unverified = refresh != .highest && family.contains { $0.isAdaptiveRefresh == nil }
        if let mode = best(of: narrowed, preferredModeIDs: preferredModeIDs) {
            return (mode, unverified ? .unverified : .exact)
        }
        guard let mode = best(of: family, preferredModeIDs: preferredModeIDs) else { return nil }
        return (mode, unverified ? .unverified : .fellBackToHighest)
    }

    private static func pixelArea(_ mode: DisplayModeInfo) -> Int {
        mode.pixelWidth * mode.pixelHeight
    }
}
