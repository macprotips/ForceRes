import Foundation

/// Persistence of per-display choices and the global scaling toggle.
///
/// Displays are keyed by their UUID string (`DisplayInfo.id`), never by `CGDirectDisplayID`.
/// Implementations are thread-safe; the app calls them from the main actor.
public protocol PreferencesStore: AnyObject, Sendable {
    /// The saved choice for a display, or nil when the user never chose anything for it.
    func choice(forDisplayID displayID: String) -> DisplayChoice?
    /// Saves (or replaces) the choice for a display.
    func setChoice(_ choice: DisplayChoice, forDisplayID displayID: String)
    /// Forgets the choice for a display.
    func removeChoice(forDisplayID displayID: String)
    /// Every saved choice keyed by display UUID.
    var allChoices: [String: DisplayChoice] { get }
    /// The "Low Resolution (1x)" toggle. Defaults to `.hiDPI`.
    var scalingPreference: ScalingPreference { get set }
    /// The mode id a display was in before ForceRes first changed it, or nil when never recorded.
    /// This is what the "Native" entry restores; it outlives the display's `DisplayChoice`.
    func originalModeID(forDisplayID displayID: String) -> Int32?
    /// Records (or, with nil, forgets) the original mode id for a display.
    func setOriginalModeID(_ modeID: Int32?, forDisplayID displayID: String)

    /// Which shape of presets the panel shows for this display. `nil` until the user picks one.
    func aspect(forDisplayID displayID: String) -> AspectRatio?

    /// Records the shape of presets to show; `nil` forgets it.
    func setAspect(_ aspect: AspectRatio?, forDisplayID displayID: String)
}

/// Keys and encoding shared by stores that persist to `UserDefaults`.
public enum PreferencesKeys {
    /// JSON-encoded `[String: DisplayChoice]`.
    public static let displayChoices = "ForceRes.displayChoices"
    /// `ScalingPreference.rawValue`.
    public static let scalingPreference = "ForceRes.scalingPreference"
    /// JSON-encoded `[String: Int32]` of original mode ids keyed by display UUID.
    public static let originalModeIDs = "ForceRes.originalModeIDs"
    public static let aspectRatios = "ForceRes.aspectRatios"
}
