import Foundation

/// The outcome of asking whether a display can show a preset.
///
/// This is the value the menu renders: `available` becomes an enabled item, `needsVirtualDisplay`
/// becomes an item the display layer serves through a virtual display + mirror (or greys out when
/// that route is missing), and `unavailable` is always greyed out with `UnavailableReason.message`.
public enum PresetAvailability: Equatable, Sendable {
    /// A native, GUI-usable mode exists. `exactScaling` is `false` when the requested scaling
    /// variant did not exist and the other one was used instead.
    case available(DisplayModeInfo, exactScaling: Bool)
    /// No native mode has the preset's pixel size; the display layer must create a virtual display.
    case needsVirtualDisplay(VirtualDisplayPlan)
    /// The preset cannot be offered on this display.
    case unavailable(UnavailableReason)
}

/// Why a preset is greyed out. `message` is the short, plain-English text shown next to the item.
public enum UnavailableReason: Equatable, Sendable, Codable {
    /// A mode with the right size exists, but macOS does not allow it for the desktop.
    case onlyUnsafeModes
    /// The display reported no modes at all.
    case noModes
    /// The preset is larger than the panel, so the display physically cannot show it.
    case exceedsPanel(panel: PixelSize)

    /// Short user-facing explanation, suitable for a menu item subtitle.
    public var message: String {
        switch self {
        case .onlyUnsafeModes: "Not supported by this display"
        case .noModes: "No display modes found"
        case .exceedsPanel(let panel): "This display is \(panel.width) × \(panel.height)"
        }
    }
}

/// What the display layer should create when a preset has no native mode.
///
/// `pixelSize` is the preset's rendered size. When `hiDPI` is set the virtual display should be
/// created with a 2x backing store so the desktop "looks like" `pixelSize` points.
public struct VirtualDisplayPlan: Equatable, Sendable, Codable {
    /// Target size of the virtual display in rendered pixels (the preset's size).
    public var pixelSize: PixelSize
    /// `true` when the user prefers the HiDPI "looks like" variant.
    public var hiDPI: Bool
    /// `true` when the preset's aspect ratio differs from the panel's by more than 1%; the
    /// mirrored image will show black bars.
    public var letterboxed: Bool
    /// `true` when the preset is wider or taller than the physical panel (e.g. 4K on a MacBook).
    /// Allowed, but the UI should label it since the panel will downscale the image.
    public var exceedsPanel: Bool

    public init(pixelSize: PixelSize, hiDPI: Bool, letterboxed: Bool, exceedsPanel: Bool) {
        self.pixelSize = pixelSize
        self.hiDPI = hiDPI
        self.letterboxed = letterboxed
        self.exceedsPanel = exceedsPanel
    }
}
