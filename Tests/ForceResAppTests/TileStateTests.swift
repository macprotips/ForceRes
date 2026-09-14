import AppKit
import ForceResCore
import ServiceManagement
import Testing
@testable import ForceRes

@Suite("Tile state derived from availability")
struct TileStateTests {
    private static let mode1080 = DisplayModeInfo(id: 1, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160,
                                                  refreshRate: 60, ioFlags: 0x3, isUsableForDesktopGUI: true)
    private static let virtualPlan = VirtualDisplayPlan(pixelSize: PixelSize(width: 1920, height: 1080), hiDPI: true,
                                                        letterboxed: false, exceedsPanel: false)

    @Test func nativeExactTile() {
        let state = TileState(preset: .fullHD1080, availability: .available(Self.mode1080, exactScaling: true),
                              isSelected: false, isVirtualSupported: true, scaling: .hiDPI)
        #expect(state.isEnabled)
        #expect(!state.isSelected)
        #expect(state.note == nil)
        #expect(state.accessibilityLabel == "1080p, 1920 by 1080")
        #expect(state.accessibilityValue == nil)
        #expect(state.accessibilityHint == "Switches the display to 1080p (1920 × 1080)")
    }

    @Test func selectedTileHasNoHint() {
        let state = TileState(preset: .uhd2160, availability: .available(Self.mode1080, exactScaling: true),
                              isSelected: true, isVirtualSupported: true, scaling: .hiDPI)
        #expect(state.isSelected)
        #expect(state.isEnabled)
        #expect(state.accessibilityLabel == "4K, 3840 by 2160")
        #expect(state.accessibilityHint == nil)
    }

    @Test func scalingFallbackIsNoted() {
        let hiDPI = TileState(preset: .hd720, availability: .available(Self.mode1080, exactScaling: false),
                              isSelected: false, isVirtualSupported: true, scaling: .hiDPI)
        #expect(hiDPI.isEnabled)
        #expect(hiDPI.note == "No HiDPI variant on this display; uses the 1x mode")
        #expect(hiDPI.accessibilityValue == hiDPI.note)
        let lowRes = TileState(preset: .hd720, availability: .available(Self.mode1080, exactScaling: false),
                               isSelected: false, isVirtualSupported: true, scaling: .lowResolution)
        #expect(lowRes.note == "No 1x variant on this display; uses the HiDPI mode")
    }

    @Test func virtualTileWithSupport() {
        let plan = VirtualDisplayPlan(pixelSize: PixelSize(width: 1920, height: 1080), hiDPI: true,
                                      letterboxed: true, exceedsPanel: false)
        let state = TileState(preset: .fullHD1080, availability: .needsVirtualDisplay(plan),
                              isSelected: false, isVirtualSupported: true, scaling: .hiDPI)
        #expect(state.isEnabled)
        #expect(state.note == "Via virtual display, 60 Hertz, letterboxed")
        #expect(state.accessibilityValue == "Via virtual display, 60 Hertz, letterboxed")
        #expect(state.accessibilityHint == "Switches the display to 1080p (1920 × 1080)")
    }

    @Test("A preset larger than the panel is disabled with the panel's size as the reason")
    func presetLargerThanThePanelIsDisabled() {
        let state = TileState(preset: .uhd2160,
                              availability: .unavailable(.exceedsPanel(panel: PixelSize(width: 2560, height: 1600))),
                              isSelected: false, isVirtualSupported: true, scaling: .hiDPI)
        #expect(!state.isEnabled)
        #expect(state.note == "This display is 2560 × 1600")
        #expect(state.accessibilityValue == "Not available on this display: This display is 2560 × 1600")
        #expect(state.accessibilityHint == nil)
    }

    @Test func virtualTileWithoutSupportIsDisabled() {
        let state = TileState(preset: .fullHD1080, availability: .needsVirtualDisplay(Self.virtualPlan),
                              isSelected: false, isVirtualSupported: false, scaling: .hiDPI)
        #expect(!state.isEnabled)
        #expect(state.note == "Not available on this Mac")
        #expect(state.accessibilityValue == "Not available on this display: Not available on this Mac")
        #expect(state.accessibilityHint == nil)
    }

    @Test func unavailableTile() {
        let state = TileState(preset: .qhd1440, availability: .unavailable(.onlyUnsafeModes),
                              isSelected: false, isVirtualSupported: true, scaling: .hiDPI)
        #expect(!state.isEnabled)
        #expect(state.note == "Not supported by this display")
        #expect(state.accessibilityValue == "Not available on this display: Not supported by this display")
        #expect(state.accessibilityHint == nil)
    }

    @Test func pendingConfirmationDisablesEveryEnabledTile() {
        let native = TileState(preset: .fullHD1080, availability: .available(Self.mode1080, exactScaling: true),
                               isSelected: false, isVirtualSupported: true, scaling: .hiDPI, isConfirmationPending: true)
        #expect(!native.isEnabled)
        #expect(native.note == "Keep or revert the current change first")
        #expect(native.accessibilityValue == native.note)
        #expect(native.accessibilityHint == nil)
        let virtual = TileState(preset: .fullHD1080, availability: .needsVirtualDisplay(Self.virtualPlan),
                                isSelected: false, isVirtualSupported: true, scaling: .hiDPI, isConfirmationPending: true)
        #expect(!virtual.isEnabled && virtual.note == "Keep or revert the current change first")
        // A tile that is unavailable anyway keeps its own reason.
        let unavailable = TileState(preset: .qhd1440, availability: .unavailable(.onlyUnsafeModes),
                                    isSelected: false, isVirtualSupported: true, scaling: .hiDPI, isConfirmationPending: true)
        #expect(unavailable.note == "Not supported by this display")
        // The selected tile is still marked selected.
        let selected = TileState(preset: .fullHD1080, availability: .available(Self.mode1080, exactScaling: true),
                                 isSelected: true, isVirtualSupported: true, scaling: .hiDPI, isConfirmationPending: true)
        #expect(selected.isSelected && !selected.isEnabled)
    }

    @Test func busyDisablesTilesWithItsOwnNote() {
        let state = TileState(preset: .fullHD1080, availability: .available(Self.mode1080, exactScaling: true),
                              isSelected: false, isVirtualSupported: true, scaling: .hiDPI, isBusy: true)
        #expect(!state.isEnabled)
        #expect(state.note == "Applying a change…")
        let both = TileState(preset: .fullHD1080, availability: .available(Self.mode1080, exactScaling: true),
                             isSelected: false, isVirtualSupported: true, scaling: .hiDPI,
                             isConfirmationPending: true, isBusy: true)
        #expect(both.note == "Keep or revert the current change first")
    }

    @Test func captionPrefersTheHoveredNoteThenTheFirstDisabledTile() {
        let plain = TileState(preset: .fullHD1080, availability: .available(Self.mode1080, exactScaling: true),
                              isSelected: false, isVirtualSupported: true, scaling: .hiDPI)
        let fallback = TileState(preset: .hd720, availability: .available(Self.mode1080, exactScaling: false),
                                 isSelected: false, isVirtualSupported: true, scaling: .hiDPI)
        let unsupported = TileState(preset: .qhd1440, availability: .unavailable(.onlyUnsafeModes),
                                    isSelected: false, isVirtualSupported: true, scaling: .hiDPI)
        let unavailable = TileState(preset: .uhd2160, availability: .needsVirtualDisplay(Self.virtualPlan),
                                    isSelected: false, isVirtualSupported: false, scaling: .hiDPI)
        let states = [plain, fallback, unsupported, unavailable]
        #expect(TileState.caption(hovered: nil, states: states) == "Not supported by this display")
        #expect(TileState.caption(hovered: fallback, states: states) == "No HiDPI variant on this display; uses the 1x mode")
        #expect(TileState.caption(hovered: unavailable, states: states) == "Not available on this Mac")
        // Hovering a plain tile falls through to the first disabled one.
        #expect(TileState.caption(hovered: plain, states: states) == "Not supported by this display")
        #expect(TileState.caption(hovered: nil, states: [plain, fallback]) == "")
    }
}

/// The preset tiles per fixture, through the model.
@Suite("Tile states per fixture")
@MainActor
struct TileStateFixtureTests {
    @Test func odysseyHiDPI() throws {
        let h = Harness(displays: [try Fixtures.display(.m4OdysseyG80SD)])
        let d = h.display
        let hd = h.model.tileState(.hd720, for: d)
        #expect(hd.isEnabled && !hd.isSelected && hd.note == nil)
        let full = h.model.tileState(.fullHD1080, for: d)
        #expect(full.isEnabled && !full.isSelected && full.note == nil)
        let qhd = h.model.tileState(.qhd1440, for: d)
        #expect(qhd.isEnabled && qhd.isSelected && qhd.note == nil)
        let uhd = h.model.tileState(.uhd2160, for: d)
        #expect(uhd.isEnabled && !uhd.isSelected)
        #expect(uhd.note == "No HiDPI variant on this display; uses the 1x mode")
    }

    @Test func odysseyLowResolution() throws {
        let h = Harness(displays: [try Fixtures.display(.m4OdysseyG80SD)], scaling: .lowResolution)
        let d = h.display
        let uhd = h.model.tileState(.uhd2160, for: d)
        #expect(uhd.isEnabled && !uhd.isSelected && uhd.note == nil)
        // The current mode is 1440p HiDPI; the selection follows the preset regardless of variant.
        #expect(h.model.tileState(.qhd1440, for: d).isSelected)
    }

    @Test func macBookAirWithVirtualSupport() throws {
        let h = Harness(displays: [try Fixtures.display(.m1MacBookAir)])
        let d = h.display
        let full = h.model.tileState(.fullHD1080, for: d)
        #expect(full.isEnabled && !full.isSelected)
        #expect(full.note == "Via virtual display, 60 Hertz, letterboxed")
        let uhd = h.model.tileState(.uhd2160, for: d)
        #expect(!uhd.isEnabled, "4K does not fit a 2560x1600 panel")
        #expect(uhd.note == "This display is 2560 × 1600")
    }

    @Test func macBookAirWithoutVirtualSupport() throws {
        let h = Harness(displays: [try Fixtures.display(.m1MacBookAir)], virtual: false)
        let full = h.model.tileState(.fullHD1080, for: h.display)
        #expect(!full.isEnabled)
        #expect(full.note == "Not available on this Mac")
    }

    @Test func external1080p() throws {
        let h = Harness(displays: [try Fixtures.display(.external1080p)])
        let d = h.display
        let hd = h.model.tileState(.hd720, for: d)
        #expect(hd.isEnabled && !hd.isSelected && hd.note == "No HiDPI variant on this display; uses the 1x mode")
        let full = h.model.tileState(.fullHD1080, for: d)
        #expect(full.isEnabled && full.isSelected && full.note == "No HiDPI variant on this display; uses the 1x mode")
        for preset in [ResolutionPreset.qhd1440, .uhd2160] {
            let state = h.model.tileState(preset, for: d)
            #expect(!state.isEnabled, "\(preset) does not fit a 1920x1080 panel")
            #expect(state.note == "This display is 1920 × 1080")
        }
    }

    @Test func displayWithoutModes() {
        let empty = DisplayInfo(id: "00000000-0000-0000-0000-00000000000E", name: "Ghost", isBuiltIn: false, isMain: false,
                                nativePixelSize: PixelSize(width: 0, height: 0), modes: [], currentModeID: nil)
        let h = Harness(displays: [empty])
        let hd = h.model.tileState(.hd720, for: h.display)
        #expect(!hd.isEnabled && hd.note == "No display modes found")
    }

    @Test func tilesAreDisabledWhileAConfirmationIsPending() throws {
        let h = Harness(displays: [try Fixtures.display(.m4OdysseyG80SD)])
        h.model.select(preset: .fullHD1080, for: h.display)
        let states = h.model.presets(for: h.display).map { h.model.tileState($0, for: h.display) }
        #expect(states.allSatisfy { !$0.isEnabled && $0.note == TileState.pendingNote })
        #expect(states[1].isSelected)
        h.model.keepPending()
        #expect(h.model.presets(for: h.display).allSatisfy { h.model.tileState($0, for: h.display).isEnabled })
    }
}

@Suite("Status icon, Launch at Login state and picker helpers")
struct PanelHelperTests {
    @Test func statusIconIsSolidOnlyWhileAPresetIsForced() {
        let forced = DisplayChoice(preset: .fullHD1080, scaling: .hiDPI)
        let native = DisplayChoice(preset: nil, scaling: .hiDPI)
        #expect(StatusIconStyle.resolve(choices: [], hasActiveMirror: false) == .outline)
        #expect(StatusIconStyle.resolve(choices: [nil, nil], hasActiveMirror: false) == .outline)
        #expect(StatusIconStyle.resolve(choices: [native], hasActiveMirror: false) == .outline)
        #expect(StatusIconStyle.resolve(choices: [nil, forced], hasActiveMirror: false) == .solid)
        #expect(StatusIconStyle.resolve(choices: [], hasActiveMirror: true) == .solid)
        #expect(StatusIconStyle.outline.resourceName == "MenuBarIcon")
        #expect(StatusIconStyle.solid.resourceName == "MenuBarIcon-Solid")
    }

    @Test func launchAtLoginStateKeepsTheToggleOnWhileApprovalIsPending() {
        #expect(LaunchAtLoginState(status: .enabled) == LaunchAtLoginState(isOn: true, requiresApproval: false))
        #expect(LaunchAtLoginState(status: .requiresApproval) == LaunchAtLoginState(isOn: true, requiresApproval: true))
        #expect(LaunchAtLoginState(status: .notRegistered) == LaunchAtLoginState(isOn: false, requiresApproval: false))
        #expect(LaunchAtLoginState(status: .notFound) == LaunchAtLoginState(isOn: false, requiresApproval: false))
    }

    @Test func displayPickerTitlesAndStyle() throws {
        let macBook = try Fixtures.display(.m1MacBookAir)
        let odyssey = try Fixtures.display(.m4OdysseyG80SD)
        #expect(PanelView.pickerTitle(for: macBook) == "Built-in Display")
        #expect(PanelView.pickerTitle(for: odyssey) == "Odyssey G80SD")
        #expect(!PanelView.usesMenuPicker(titles: ["Odyssey G80SD", "LG UltraFine"]))
        // "Built-in Display" is 16 characters, so a MacBook with an external display gets the pull-down.
        #expect(PanelView.usesMenuPicker(titles: ["Odyssey G80SD", "Built-in Display"]))
        #expect(PanelView.usesMenuPicker(titles: ["Odyssey G80SD", "DELL U2723QE (2)"]))
        #expect(PanelView.usesMenuPicker(titles: ["A", "B", "C", "D"]))
    }

    @Test func panelRhythm() {
        // The bottom row sits in the same rhythm as the header, and the gear centres on the
        // title's capitals: a small shift from the line-box centre, never a visible jump.
        #expect(PanelMetrics.bottomPadding == PanelMetrics.topPadding)
        #expect(abs(PanelMetrics.gearTopOffset) < 4)
    }

    @Test func refreshValueLabelOmitsTheUnknownPlaceholder() {
        let known = RefreshControlState(options: [.fixed(hertz: 60), .fixed(hertz: 30)], current: .fixed(hertz: 60), isProMotion: false)
        #expect(known.valueLabel == "60 Hertz")
        let unknown = RefreshControlState(options: known.options, current: nil, isProMotion: false)
        #expect(unknown.label == RefreshControlState.unknownLabel && unknown.valueLabel == nil)
        let mirrored = RefreshControlState(options: [], current: nil, isProMotion: false, isVirtualMirror: true)
        #expect(mirrored.valueLabel == "60 Hertz" && !mirrored.isEnabled && mirrored.note == RefreshControlState.virtualNote)
    }
}

private extension LaunchAtLoginState {
    init(isOn: Bool, requiresApproval: Bool) {
        self.init(status: .notRegistered)
        self.isOn = isOn
        self.requiresApproval = requiresApproval
    }
}
