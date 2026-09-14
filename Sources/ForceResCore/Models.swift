import Foundation

/// A single display mode as reported by CoreGraphics, decoupled from CGDisplayMode so it can be
/// recorded to JSON fixtures and unit tested without a display attached.
public struct DisplayModeInfo: Codable, Hashable, Sendable, Identifiable {
    /// `CGDisplayModeGetIODisplayModeID`. Unique per display within one enumeration.
    public var id: Int32
    /// Logical (point) size, what `NSScreen.frame` reports.
    public var width: Int
    public var height: Int
    /// Backing pixel size. Equal to `width`/`height` for 1x modes, double for HiDPI "looks like" modes.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Hz. Zero means "unknown/adaptive" (some built-in ProMotion entries).
    public var refreshRate: Double
    /// Raw `CGDisplayModeGetIOFlags`. See `IOFlags`.
    public var ioFlags: UInt32
    /// `CGDisplayModeIsUsableForDesktopGUI`. Empirically identical to `IOFlags.safe` being set.
    public var isUsableForDesktopGUI: Bool
    /// `true` for the variable-refresh twin of a duplicate pair (SkyLight `SLSIsDisplayModeVRR`,
    /// docs/RESEARCH.md section 11). `nil` when the classifier was unavailable or never ran.
    public var isVariableRefresh: Bool?
    /// `true` for a ProMotion entry (SkyLight `SLSIsDisplayModeProMotion`). `nil` when unknown.
    public var isProMotion: Bool?

    public init(id: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int,
                refreshRate: Double, ioFlags: UInt32, isUsableForDesktopGUI: Bool,
                isVariableRefresh: Bool? = nil, isProMotion: Bool? = nil) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.ioFlags = ioFlags
        self.isUsableForDesktopGUI = isUsableForDesktopGUI
        self.isVariableRefresh = isVariableRefresh
        self.isProMotion = isProMotion
    }

    /// IOKit `IOGraphicsTypes.h` display-mode flags used by ForceRes.
    public enum IOFlags {
        public static let valid: UInt32 = 0x0000_0001
        public static let safe: UInt32 = 0x0000_0002
        public static let `default`: UInt32 = 0x0000_0004
        public static let interlaced: UInt32 = 0x0000_0040
        public static let stretched: UInt32 = 0x0000_0800
        public static let native: UInt32 = 0x0200_0000
    }

    /// Whether this entry runs with an adaptive (variable) refresh rate: `isVariableRefresh`
    /// when the SkyLight classifier answered, otherwise `isProMotion` (a ProMotion entry is the
    /// adaptive one, docs/RESEARCH.md section 11), otherwise `nil` (unclassified). Every rule in
    /// `ModeSelector` reads this rather than the two raw fields.
    public var isAdaptiveRefresh: Bool? { isVariableRefresh ?? isProMotion }

    public var isHiDPI: Bool { pixelWidth > width }
    /// `refreshRate` rounded to whole Hz (59.94 → 60); 0 stays 0 for adaptive entries.
    public var roundedRefreshRate: Int { Int(refreshRate.rounded()) }
    public var isSafe: Bool { ioFlags & IOFlags.safe != 0 }
    public var isNativeTiming: Bool { ioFlags & IOFlags.native != 0 }
    public var isInterlaced: Bool { ioFlags & IOFlags.interlaced != 0 }
    public var isStretched: Bool { ioFlags & IOFlags.stretched != 0 }
    public var pixelSize: PixelSize { PixelSize(width: pixelWidth, height: pixelHeight) }
    public var pointSize: PixelSize { PixelSize(width: width, height: height) }
}

/// A width/height pair in pixels (or points).
public struct PixelSize: Codable, Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var description: String { "\(width)x\(height)" }
    public var aspectRatio: Double { Double(width) / Double(height) }
}

/// The shape of the presets on offer: 16:9 for external displays, 16:10 for the panels every
/// MacBook uses. Changing it only relabels the tiles, never the display.
public enum AspectRatio: String, CaseIterable, Codable, Sendable, Identifiable {
    case sixteenByNine
    case sixteenByTen

    public var id: String { rawValue }

    /// "16:9". Used in the menu and in spoken descriptions.
    public var title: String {
        switch self {
        case .sixteenByNine: "16:9"
        case .sixteenByTen: "16:10"
        }
    }

    /// The four presets offered for this shape, widest first.
    public var presets: [ResolutionPreset] {
        switch self {
        case .sixteenByNine: [.hd720, .fullHD1080, .qhd1440, .uhd2160]
        case .sixteenByTen: [.wxga800, .hdPlus900, .wsxga1050, .wuxga1200]
        }
    }

    /// The shape whose presets contain `preset`.
    public static func containing(_ preset: ResolutionPreset) -> AspectRatio {
        allCases.first { $0.presets.contains(preset) } ?? .sixteenByNine
    }
}

/// The four resolutions ForceRes offers. `pixelSize` is the *rendered pixel* target; a HiDPI
/// variant of the same preset has `pointSize == pixelSize / 2`. The 16:9 raw values predate the
/// other shapes and are kept as they are so stored choices survive an upgrade.
public enum ResolutionPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case hd720
    case fullHD1080
    case qhd1440
    case uhd2160
    case wxga800
    case hdPlus900
    case wsxga1050
    case wuxga1200

    public var id: String { rawValue }

    public var aspect: AspectRatio { AspectRatio.containing(self) }

    public var pixelSize: PixelSize {
        switch self {
        case .hd720: PixelSize(width: 1280, height: 720)
        case .fullHD1080: PixelSize(width: 1920, height: 1080)
        case .qhd1440: PixelSize(width: 2560, height: 1440)
        case .uhd2160: PixelSize(width: 3840, height: 2160)
        case .wxga800: PixelSize(width: 1280, height: 800)
        case .hdPlus900: PixelSize(width: 1440, height: 900)
        case .wsxga1050: PixelSize(width: 1680, height: 1050)
        case .wuxga1200: PixelSize(width: 1920, height: 1200)
        }
    }

    /// Short tile title. The 16:9 sizes use the names people know; the rest use the height, which
    /// keeps every tile the same shape. The exact size is always one hover away.
    public var title: String {
        switch self {
        case .uhd2160: "4K"
        default: "\(pixelSize.height)p"
        }
    }

    /// Longer label, e.g. "1080p (1920 × 1080)".
    public var detailedTitle: String { "\(title) (\(pixelSize.width) × \(pixelSize.height))" }
}

/// Whether the user wants the HiDPI "looks like" variant or the true 1x framebuffer.
public enum ScalingPreference: String, Codable, Sendable, CaseIterable {
    /// Prefer a mode whose point size is the preset and whose pixel size is 2x. Falls back to 1x.
    case hiDPI
    /// Prefer a mode whose pixel size *and* point size equal the preset ("Low Resolution").
    case lowResolution
}

/// A connected display, as recorded for fixtures and as passed around the app.
public struct DisplayInfo: Codable, Hashable, Sendable, Identifiable {
    /// Stable identity: `CGDisplayCreateUUIDFromDisplayID` as a string. Never a CGDirectDisplayID.
    public var id: String
    /// Human name from the display's localized name (or a fallback like "Display 3").
    public var name: String
    public var isBuiltIn: Bool
    public var isMain: Bool
    /// The panel's native pixel size, derived from the mode carrying `IOFlags.native` when present,
    /// otherwise the largest 1x mode.
    public var nativePixelSize: PixelSize
    /// Every mode from `CGDisplayCopyAllDisplayModes` with `kCGDisplayShowDuplicateLowResolutionModes`.
    public var modes: [DisplayModeInfo]
    /// `CGDisplayCopyDisplayMode` at capture time, matched by `id` into `modes` when possible.
    public var currentModeID: Int32?
    /// Backed by a real panel (built-in, or an IORegistry framebuffer with matching vendor and
    /// product ids). Virtual displays, ours or anyone else's, are `false` and are never mirrored.
    public var isPhysical: Bool
    /// The panel's variable-refresh window in Hz (IOKit `MinimumVariableRefreshRate` …
    /// `MaximumVariableRefreshRate`), or `nil` when unsupported or unknown. Stored in JSON as
    /// `minHertz`/`maxHertz`.
    public var variableRefreshRange: ClosedRange<Double>?

    public init(id: String, name: String, isBuiltIn: Bool, isMain: Bool, nativePixelSize: PixelSize,
                modes: [DisplayModeInfo], currentModeID: Int32?, isPhysical: Bool = true,
                variableRefreshRange: ClosedRange<Double>? = nil) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.nativePixelSize = nativePixelSize
        self.modes = modes
        self.currentModeID = currentModeID
        self.isPhysical = isPhysical
        self.variableRefreshRange = variableRefreshRange
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isBuiltIn, isMain, nativePixelSize, modes, currentModeID, isPhysical
        case minHertz, maxHertz
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        isMain = try c.decode(Bool.self, forKey: .isMain)
        nativePixelSize = try c.decode(PixelSize.self, forKey: .nativePixelSize)
        modes = try c.decode([DisplayModeInfo].self, forKey: .modes)
        currentModeID = try c.decodeIfPresent(Int32.self, forKey: .currentModeID)
        isPhysical = try c.decodeIfPresent(Bool.self, forKey: .isPhysical) ?? true
        if let lo = try c.decodeIfPresent(Double.self, forKey: .minHertz),
           let hi = try c.decodeIfPresent(Double.self, forKey: .maxHertz), lo <= hi {
            variableRefreshRange = lo...hi
        } else {
            variableRefreshRange = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isBuiltIn, forKey: .isBuiltIn)
        try c.encode(isMain, forKey: .isMain)
        try c.encode(nativePixelSize, forKey: .nativePixelSize)
        try c.encode(modes, forKey: .modes)
        try c.encodeIfPresent(currentModeID, forKey: .currentModeID)
        try c.encode(isPhysical, forKey: .isPhysical)
        try c.encodeIfPresent(variableRefreshRange?.lowerBound, forKey: .minHertz)
        try c.encodeIfPresent(variableRefreshRange?.upperBound, forKey: .maxHertz)
    }

    public var currentMode: DisplayModeInfo? {
        guard let currentModeID else { return nil }
        return modes.first { $0.id == currentModeID }
    }
}

/// Top-level fixture document produced by `forceres-probe --json`.
public struct DisplaySnapshot: Codable, Sendable {
    public var capturedAt: Date
    public var machine: String
    public var osVersion: String
    public var displays: [DisplayInfo]
    public init(capturedAt: Date, machine: String, osVersion: String, displays: [DisplayInfo]) {
        self.capturedAt = capturedAt
        self.machine = machine
        self.osVersion = osVersion
        self.displays = displays
    }
}
