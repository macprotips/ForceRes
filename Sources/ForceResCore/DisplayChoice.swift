import Foundation

/// What the user asked for on one display. A `nil` preset means "Native" (the display's default
/// mode); `scaling` records which variant was in force when the choice was made so it can be
/// re-applied faithfully on launch and on reconfiguration; `refresh` is the rate preference for
/// that resolution (`.highest` unless the user picked a rate).
///
/// JSON: `refresh` is omitted when it is `.highest`, so choices saved before refresh support
/// decode unchanged and the stored bytes for the default stay stable.
public struct DisplayChoice: Codable, Equatable, Sendable {
    public var preset: ResolutionPreset?
    public var scaling: ScalingPreference
    public var refresh: RefreshPreference

    public init(preset: ResolutionPreset?, scaling: ScalingPreference, refresh: RefreshPreference = .highest) {
        self.preset = preset
        self.scaling = scaling
        self.refresh = refresh
    }

    private enum CodingKeys: String, CodingKey { case preset, scaling, refresh }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decodeIfPresent(ResolutionPreset.self, forKey: .preset)
        scaling = try c.decode(ScalingPreference.self, forKey: .scaling)
        refresh = try c.decodeIfPresent(RefreshPreference.self, forKey: .refresh) ?? .highest
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(preset, forKey: .preset)
        try c.encode(scaling, forKey: .scaling)
        if refresh != .highest { try c.encode(refresh, forKey: .refresh) }
    }
}
