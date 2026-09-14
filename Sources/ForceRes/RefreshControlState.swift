import ForceResCore

/// Everything the refresh-rate pull-down needs for one display, derived from pure inputs so the
/// labels, enabled flag and note can be unit tested without SwiftUI.
struct RefreshControlState: Equatable, Sendable {
    /// Shown while the display mirrors one of our virtual displays (macOS harmonises mirror
    /// targets to the 60 Hz master, so there is no rate to choose).
    static let virtualNote = "Virtual displays run at 60 Hertz"
    /// The control's label when the current rate is unknown.
    static let unknownLabel = "Refresh rate"
    /// Shown when the current option cannot be named: the classifier is unavailable and the
    /// current mode has a twin at its rate (docs/RESEARCH.md section 11).
    static let unverifiedNote = "Refresh rate can't be verified on this Mac"
    /// The caption after a `RefreshOutcome.unverified` selection.
    static let unverifiedFallbackNote = "Couldn't verify the refresh rate on this Mac"

    /// What the display enumerates for the resolution in effect: Variable/ProMotion first, then
    /// fixed rates descending. Empty while a virtual mirror is active.
    var options: [RefreshOption]
    /// The option the display is on, when known.
    var current: RefreshOption?
    /// `false` renders the control greyed out with no menu.
    var isEnabled: Bool
    /// Why the control is disabled; `nil` when enabled or when there is simply one option.
    var note: String?
    /// The `note` of a disabled control, else `fallbackNote`, else `nil`: what the caption and
    /// VoiceOver report alongside the control.
    var caption: String?
    /// Label of the current option, e.g. "240 Hertz", "Variable (48–240 Hertz)", "ProMotion".
    var label: String
    /// `true` renders the variable option as "ProMotion" (built-in panels).
    var isProMotion: Bool

    /// - Parameters:
    ///   - options: `ModeSelector.availableRefreshOptions` for the display's current family.
    ///   - current: `ModeSelector.currentRefreshOption`.
    ///   - isProMotion: the display is built in and its variable entry is a ProMotion one.
    ///   - isVirtualMirror: the display mirrors one of our virtual displays.
    ///   - isConfirmationPending: `AppModel.pendingConfirmation != nil`; disables the control.
    ///   - isBusy: `AppModel.isBusy`; disables the control.
    ///   - fallbackNote: `AppModel.refreshFallbackNote(for:)`, the caption of an enabled control.
    init(options: [RefreshOption], current: RefreshOption?, isProMotion: Bool,
         isVirtualMirror: Bool = false, isConfirmationPending: Bool = false, isBusy: Bool = false,
         fallbackNote: String? = nil) {
        self.isProMotion = isProMotion
        if isVirtualMirror {
            self.options = []
            self.current = .fixed(hertz: 60)
            isEnabled = false
            note = Self.virtualNote
            caption = note
            label = Self.label(for: .fixed(hertz: 60), isProMotion: false)
            return
        }
        self.options = options
        self.current = current
        let shown = current ?? (options.count == 1 ? options.first : nil)
        label = shown.map { Self.label(for: $0, isProMotion: isProMotion) } ?? Self.unknownLabel
        if isConfirmationPending {
            isEnabled = false
            note = TileState.pendingNote
        } else if isBusy {
            isEnabled = false
            note = TileState.busyNote
        } else if options.count > 1, current == nil {
            // Rates to choose from, but no way to tell which one is in effect.
            isEnabled = false
            note = Self.unverifiedNote
        } else {
            isEnabled = options.count > 1
        }
        caption = isEnabled ? fallbackNote : note
    }

    /// The value shown after the "Refresh rate" prefix; `nil` while the rate is unknown, so the
    /// control reads "Refresh rate" alone rather than repeating it.
    var valueLabel: String? { label == Self.unknownLabel ? nil : label }

    /// The menu title of `option`.
    func label(for option: RefreshOption) -> String {
        Self.label(for: option, isProMotion: isProMotion)
    }

    /// "240 Hertz"; "ProMotion" for a built-in adaptive panel; "Variable (48–240 Hertz)" when
    /// the range is known, else "Variable".
    static func label(for option: RefreshOption, isProMotion: Bool) -> String {
        switch option {
        case .fixed(let rate):
            return hertz(rate)
        case .variable(let minHertz, let maxHertz):
            if isProMotion { return "ProMotion" }
            guard let minHertz, let maxHertz else { return "Variable" }
            return "Variable (\(Int(minHertz.rounded()))–\(Int(maxHertz.rounded())) Hertz)"
        }
    }

    /// "120 Hertz".
    static func hertz(_ hertz: Int) -> String { Units.hertz(hertz) }

    /// "60 Hertz isn't available at 4K; using the highest rate".
    static func fallbackNote(refresh: RefreshPreference, preset: ResolutionPreset?) -> String? {
        let wanted: String
        switch refresh {
        case .highest: return nil
        case .fixed(let hertz): wanted = Self.hertz(hertz)
        case .variable: wanted = "Variable refresh"
        }
        return "\(wanted) isn't available at \(preset?.title ?? "this resolution"); using the highest rate"
    }
}
