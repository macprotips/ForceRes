import Foundation

/// What refresh rate the user wants for the resolution in effect on one display.
///
/// JSON is a keyed object with a stable `kind` discriminator: `{"kind":"highest"}`,
/// `{"kind":"fixed","hertz":60}`, `{"kind":"variable"}`.
public enum RefreshPreference: Codable, Hashable, Sendable, CustomDebugStringConvertible {
    /// The highest enumerated rate, preferring the variable-refresh twin the way macOS does.
    case highest
    /// A fixed rate in whole Hz (rounded; 59.94 counts as 60). Never a variable-refresh entry.
    case fixed(hertz: Int)
    /// The variable-refresh ("Variable"/"Adaptive"/"ProMotion") entry at its highest rate.
    case variable

    private enum CodingKeys: String, CodingKey { case kind, hertz }
    private enum Kind: String, Codable { case highest, fixed, variable }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .highest: self = .highest
        case .fixed: self = .fixed(hertz: try c.decode(Int.self, forKey: .hertz))
        case .variable: self = .variable
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .highest: try c.encode(Kind.highest, forKey: .kind)
        case .fixed(let hertz):
            try c.encode(Kind.fixed, forKey: .kind)
            try c.encode(hertz, forKey: .hertz)
        case .variable: try c.encode(Kind.variable, forKey: .kind)
        }
    }

    public var debugDescription: String {
        switch self {
        case .highest: "highest"
        case .fixed(let hertz): "fixed(\(hertz) Hz)"
        case .variable: "variable"
        }
    }
}

/// One entry of the refresh-rate control for a given resolution: what the display actually
/// enumerates for that pixel size and scaling (never a hard-coded list).
///
/// JSON uses the same `kind` discriminator as `RefreshPreference`: `{"kind":"fixed","hertz":120}`,
/// `{"kind":"variable","minHertz":48,"maxHertz":240}` (range keys omitted when unknown).
public enum RefreshOption: Codable, Hashable, Sendable, CustomDebugStringConvertible {
    /// A variable-refresh entry exists; `minHertz`/`maxHertz` come from IOKit when known.
    case variable(minHertz: Double?, maxHertz: Double?)
    /// A fixed rate in whole Hz.
    case fixed(hertz: Int)

    private enum CodingKeys: String, CodingKey { case kind, hertz, minHertz, maxHertz }
    private enum Kind: String, Codable { case variable, fixed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .variable:
            self = .variable(minHertz: try c.decodeIfPresent(Double.self, forKey: .minHertz),
                             maxHertz: try c.decodeIfPresent(Double.self, forKey: .maxHertz))
        case .fixed:
            self = .fixed(hertz: try c.decode(Int.self, forKey: .hertz))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .variable(let minHertz, let maxHertz):
            try c.encode(Kind.variable, forKey: .kind)
            try c.encodeIfPresent(minHertz, forKey: .minHertz)
            try c.encodeIfPresent(maxHertz, forKey: .maxHertz)
        case .fixed(let hertz):
            try c.encode(Kind.fixed, forKey: .kind)
            try c.encode(hertz, forKey: .hertz)
        }
    }

    /// The `RefreshPreference` that asks for exactly this option.
    public var preference: RefreshPreference {
        switch self {
        case .variable: .variable
        case .fixed(let hertz): .fixed(hertz: hertz)
        }
    }

    public var debugDescription: String {
        switch self {
        case .variable(let lo, let hi):
            if let lo, let hi { "variable(\(Int(lo.rounded()))-\(Int(hi.rounded())) Hz)" } else { "variable" }
        case .fixed(let hertz): "fixed(\(hertz) Hz)"
        }
    }
}

/// Whether a `RefreshPreference` could be honoured by `ModeSelector`.
public enum RefreshOutcome: Hashable, Sendable {
    /// The chosen mode satisfies the preference (`.highest` is always exact).
    case exact
    /// No mode matched `.fixed`/`.variable`; the `.highest` rule was used instead.
    case fellBackToHighest
    /// A `.fixed`/`.variable` request on a family with at least one unclassified entry
    /// (`isAdaptiveRefresh == nil`, the classifier was unavailable): fixed and variable twins are
    /// byte-identical to public API (docs/RESEARCH.md section 11), so the pick is the best
    /// candidate by the usual ranking but the preference may not actually be honoured.
    case unverified
}

/// The full result of one `ModeSelector.select` call.
public struct ModeSelection: Hashable, Sendable {
    /// The mode to apply.
    public var mode: DisplayModeInfo
    /// `false` when the requested scaling variant did not exist and the other one was used.
    public var exactScaling: Bool
    /// Whether the refresh preference was honoured.
    public var refreshOutcome: RefreshOutcome

    public init(mode: DisplayModeInfo, exactScaling: Bool, refreshOutcome: RefreshOutcome) {
        self.mode = mode
        self.exactScaling = exactScaling
        self.refreshOutcome = refreshOutcome
    }
}
