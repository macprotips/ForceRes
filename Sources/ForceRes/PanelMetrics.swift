import SwiftUI

/// Every layout number the popover panel uses. The set is tuned as a whole: changing one
/// value in isolation breaks the alignment the header, tiles and bottom row share.
enum PanelMetrics {
    // MARK: Panel

    /// Inner horizontal padding between the popover edge and the content.
    static let horizontalPadding: CGFloat = 21
    static let topPadding: CGFloat = 15
    /// Matches the top padding so the bottom row sits in the same rhythm as the header.
    static let bottomPadding: CGFloat = 15
    /// Content width: four tiles, three gaps. The panel is sized to fit this plus the padding.
    static var contentWidth: CGFloat { tileWidth * 4 + tileGap * 3 }

    // MARK: Header

    static let titleSize: CGFloat = 18
    static let subtitleSize: CGFloat = 11
    /// Gap between the title baseline block and the subtitle.
    static let titleToSubtitle: CGFloat = 3
    /// Gap between the header (or the display picker) and the tile row.
    static let headerToTiles: CGFloat = 13
    /// Gap between the header and the display picker when several displays are connected.
    static let headerToPicker: CGFloat = 10
    static let gearSymbolSize: CGFloat = 14
    /// One tooth of the gear glyph: hovering turns it that far and no further, so it reads as a
    /// click into the next notch rather than a spin.
    static let gearHoverRotation: Double = 45
    static let gearRotationDuration: Double = 0.25
    /// Square hit target for the gear button.
    static let gearHitSize: CGFloat = 24
    /// How far the gear's hit target extends past its glyph on each side; the header pulls the
    /// button out by this much so the glyph's right edge lines up with the tile row's.
    static var gearOverhang: CGFloat { (gearHitSize - gearSymbolSize) / 2 }
    /// Vertical offset that centres the gear on the title's cap height rather than on the
    /// title's line box, measured once from the title font's metrics.
    static let gearTopOffset: CGFloat = {
        let font = NSFont.systemFont(ofSize: titleSize, weight: .semibold)
        return capHeightCentre(of: font) - gearHitSize / 2
    }()

    /// Distance from the top of a single-line text box in `font` to the middle of its capitals.
    static func capHeightCentre(of font: NSFont) -> CGFloat {
        font.ascender - font.capHeight / 2
    }

    // MARK: Tiles

    static let tileWidth: CGFloat = 85
    static let tileHeight: CGFloat = 62
    static let tileGap: CGFloat = 9
    static let tileCornerRadius: CGFloat = 11
    /// Glyph size for the smallest preset in a row; each step up adds `tileSymbolStep`, so the
    /// row reads as a ladder at a glance the way Display settings draws its size choices.
    static let tileSymbolSize: CGFloat = 16
    static let tileSymbolStep: CGFloat = 2

    /// Glyph size for the `step`-th tile of four.
    static func tileSymbolSize(step: Int) -> CGFloat {
        tileSymbolSize + CGFloat(max(0, step)) * tileSymbolStep
    }
    static let tileLabelSize: CGFloat = 13
    static let tileSymbolToLabel: CGFloat = 7
    /// Opacity of a tile the display cannot show.
    static let disabledOpacity: Double = 0.45
    /// Opacity of the tile row while a change is being applied.
    static let busyOpacity: Double = 0.6
    /// Ease-out duration for the selection moving between tiles (skipped under Reduce Motion).
    static let selectionAnimationDuration: Double = 0.15
    /// Opacity of the hairline stroke around an unselected tile.
    static let tileStrokeOpacity: Double = 0.5
    /// Brightness shifts of the tile fill: the selected tile lifts on hover and drops when
    /// pressed; an unselected tile only drops when pressed.
    static let selectedHoverBrightness: Double = 0.03
    static let selectedPressedBrightness: Double = -0.05
    static let pressedBrightness: Double = -0.03

    // MARK: Bottom row (refresh-rate control and caption)

    /// Gap between the tile row and the bottom row.
    static let tilesToBottomRow: CGFloat = 12
    /// Fixed height of the bottom row, so the panel is stable whether the caption is empty or not.
    static let bottomRowHeight: CGFloat = 21
    /// Gap between the refresh-rate control and the caption.
    static let refreshToCaption: CGFloat = 10
    /// Text size of the refresh-rate control's prefix and value.
    static let refreshLabelSize: CGFloat = 10
    /// Size of the pop-up chevron on the refresh-rate control.
    static let refreshChevronSize: CGFloat = 8
    /// Gap between the "Refresh rate" prefix and the value.
    static let refreshPrefixToValue: CGFloat = 5
    /// Gap between the value and the chevron.
    static let refreshValueToChevron: CGFloat = 5
    static let captionSize: CGFloat = 10

    // MARK: Borderless controls (gear, refresh rate)

    /// Corner radius of the hover fill behind the gear and the refresh-rate control.
    static let controlCornerRadius: CGFloat = 6
    /// Inset between the refresh-rate control's text and its hover fill.
    static let controlInsets = SwiftUI.EdgeInsets(top: 4, leading: 7, bottom: 4, trailing: 7)
    /// Gap between a control's bottom edge and the top of the menu it pops.
    static let menuGap: CGFloat = 2

    // MARK: Confirmation panel

    /// Initial content size before the panel is fitted to its SwiftUI content.
    static let confirmationInitialSize = CGSize(width: 380, height: 140)
    static let confirmationMinWidth: CGFloat = 360
    static let confirmationPadding: CGFloat = 20
    static let confirmationSpacing: CGFloat = 12
}
