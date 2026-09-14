import Testing
import ForceResCore

@Suite("ModeSelector on the M4 + Odyssey G80SD dump")
struct OdysseyG80SDTests {
    let display = try! FixtureLoader.display(.m4OdysseyG80SD)

    @Test func fixtureHasAll242Modes() {
        #expect(display.modes.count == 242)
        #expect(display.modes.filter(\.isUsableForDesktopGUI).count == 167)
        #expect(display.nativePixelSize == PixelSize(width: 3840, height: 2160))
        #expect(display.currentMode?.id == 133)
    }

    @Test("HiDPI variants resolve to the 240 Hz variable-refresh twin with exact scaling",
          arguments: [(ResolutionPreset.hd720, Int32(41)), (.fullHD1080, 102), (.qhd1440, 133)])
    func hiDPIPresets(preset: ResolutionPreset, expectedID: Int32) {
        let result = ModeSelector.availability(of: preset, scaling: .hiDPI, for: display)
        guard case .available(let mode, let exact) = result else {
            Issue.record("expected available, got \(result)")
            return
        }
        #expect(mode.id == expectedID)
        #expect(mode.isHiDPI)
        #expect(mode.pointSize == preset.pixelSize)
        #expect(mode.refreshRate == 240)
        #expect(mode.isSafe && mode.isUsableForDesktopGUI)
        #expect(mode.isVariableRefresh == true)
        #expect(exact)
    }

    @Test("1x variants resolve to the 240 Hz variable-refresh twin with exact scaling",
          arguments: [(ResolutionPreset.hd720, Int32(43)), (.fullHD1080, 104), (.qhd1440, 135), (.uhd2160, 163)])
    func lowResolutionPresets(preset: ResolutionPreset, expectedID: Int32) {
        let result = ModeSelector.availability(of: preset, scaling: .lowResolution, for: display)
        guard case .available(let mode, let exact) = result else {
            Issue.record("expected available, got \(result)")
            return
        }
        #expect(mode.id == expectedID)
        #expect(!mode.isHiDPI)
        #expect(mode.pixelSize == preset.pixelSize)
        #expect(mode.refreshRate == 240)
        #expect(mode.isSafe && mode.isUsableForDesktopGUI)
        #expect(mode.isVariableRefresh == true)
        #expect(exact)
    }

    @Test("4K HiDPI has no 7680x4320 backing mode, so it falls back to 1x 4K @ 240 (variable twin)")
    func uhdHiDPIFallsBackToNative1x() {
        let result = ModeSelector.availability(of: .uhd2160, scaling: .hiDPI, for: display)
        #expect(result == .available(display.modes[163], exactScaling: false))
        #expect(display.modes[163].id == 163)
        #expect(display.modes[163].refreshRate == 240)
        #expect(display.modes[163].isNativeTiming)
        #expect(display.modes[163].isVariableRefresh == true)
    }

    @Test("Every 16:9 preset is available, and selectMode agrees with availability everywhere")
    func selectModeMatchesAvailability() {
        for preset in ResolutionPreset.allCases {
            for scaling in ScalingPreference.allCases {
                let selected = ModeSelector.selectMode(for: preset, scaling: scaling, in: display.modes)
                let availability = ModeSelector.availability(of: preset, scaling: scaling, for: display)
                guard case .available(let mode, _) = availability else {
                    // Only the 16:9 ladder is guaranteed on this panel; the wider shapes have
                    // sizes it does not enumerate.
                    #expect(preset.aspect != .sixteenByNine, "\(preset)/\(scaling) should be available")
                    #expect(selected == nil)
                    continue
                }
                #expect(selected == mode)
            }
        }
    }

    @Test("The 1080p HiDPI @ 240 mode with the default flag is the fallback for the Native entry")
    func defaultModeIsFlaggedDefault() {
        let mode = ModeSelector.defaultMode(in: display.modes)
        #expect(mode?.id == 103)
        #expect(mode?.ioFlags == 0x0200_0007)
    }

    @Test("132 and 133 are 1440p HiDPI @ 240 twins differing only in the VRR flag; the variable twin wins")
    func duplicateModesResolveToTheVariableTwin() throws {
        let twin132 = try #require(display.modes.first { $0.id == 132 })
        var twin133 = try #require(display.modes.first { $0.id == 133 })
        #expect(twin132.isVariableRefresh == false && twin133.isVariableRefresh == true)
        twin133.id = 132
        twin133.isVariableRefresh = false
        #expect(twin132 == twin133)

        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: display.modes)?.id == 133)
        // The VRR tie-break comes before preferred ids: the fixed twin cannot be preferred back in.
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: display.modes,
                                        preferredModeIDs: [132])?.id == 133)
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: display.modes,
                                        preferredModeIDs: [999, 133, 132])?.id == 133)
        guard case .available(let mode, let exact) = ModeSelector.availability(of: .qhd1440, scaling: .hiDPI,
                                                                                for: display, preferredModeIDs: [133]) else {
            Issue.record("expected available")
            return
        }
        #expect(mode.id == 133 && exact)
        // A preferred id from another preset never leaks into this one.
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .hiDPI, in: display.modes,
                                        preferredModeIDs: [133])?.id == 102)
        // The 1080p twins: 102 is the variable one and wins even when the default-flagged 103 is preferred.
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .hiDPI, in: display.modes,
                                        preferredModeIDs: [103])?.id == 102)
    }

    @Test("Unclassified twins (no VRR flag) still resolve by preferred id, then lowest id")
    func unclassifiedDuplicatesResolveToThePreferredID() {
        let unclassified = display.modes.map { mode in
            var mode = mode
            mode.isVariableRefresh = nil
            return mode
        }
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: unclassified)?.id == 132)
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: unclassified,
                                        preferredModeIDs: [133])?.id == 133)
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .hiDPI, in: unclassified,
                                        preferredModeIDs: [103])?.id == 103)
    }

    @Test("Native restores the recorded original (133), falling back to the default-flagged 103")
    func restoreModePrefersTheRecordedOriginal() {
        #expect(ModeSelector.restoreMode(in: display.modes, originalModeID: 133)?.id == 133)
        #expect(ModeSelector.restoreMode(in: display.modes, originalModeID: 132)?.id == 132)
        #expect(ModeSelector.restoreMode(in: display.modes, originalModeID: nil)?.id == 103)
        #expect(ModeSelector.restoreMode(in: display.modes, originalModeID: 9999)?.id == 103)
        // An original that is no longer usable for the desktop GUI is not restored.
        if let unusable = display.modes.first(where: { !$0.isUsableForDesktopGUI }) {
            #expect(ModeSelector.restoreMode(in: display.modes, originalModeID: unusable.id)?.id == 103)
        } else {
            Issue.record("fixture should contain a mode unusable for the desktop GUI")
        }
    }

    @Test func currentPresetIs1440pHiDPI() {
        let hi = ModeSelector.currentPreset(for: display, scaling: .hiDPI)
        #expect(hi?.preset == .qhd1440)
        #expect(hi?.exact == true)
        let low = ModeSelector.currentPreset(for: display, scaling: .lowResolution)
        #expect(low?.preset == .qhd1440)
        #expect(low?.exact == false)
    }

    @Test func nativePixelSizeComesFromNativeFlaggedModes() {
        #expect(ModeSelector.nativePixelSize(from: display.modes) == PixelSize(width: 3840, height: 2160))
    }
}

@Suite("ModeSelector on the synthetic M1 MacBook Air panel")
struct MacBookAirTests {
    let display = try! FixtureLoader.display(.m1MacBookAir)

    @Test func fixtureShape() {
        #expect(display.modes.count == 16)
        #expect(display.isBuiltIn)
        #expect(display.nativePixelSize == PixelSize(width: 2560, height: 1600))
        #expect(!display.modes.contains { $0.pixelSize.aspectRatio == 16.0 / 9.0 })
    }

    @Test("Every preset needs a virtual display with the right plan",
          arguments: ScalingPreference.allCases)
    func everyPresetNeedsVirtualDisplay(scaling: ScalingPreference) {
        let hi = scaling == .hiDPI
        let expected: [ResolutionPreset: VirtualDisplayPlan] = [
            .hd720: .init(pixelSize: .init(width: 1280, height: 720), hiDPI: hi, letterboxed: true, exceedsPanel: false),
            .fullHD1080: .init(pixelSize: .init(width: 1920, height: 1080), hiDPI: hi, letterboxed: true, exceedsPanel: false),
            .qhd1440: .init(pixelSize: .init(width: 2560, height: 1440), hiDPI: hi, letterboxed: true, exceedsPanel: false),
        ]
        for preset in AspectRatio.sixteenByNine.presets where preset != .uhd2160 {
            let result = ModeSelector.availability(of: preset, scaling: scaling, for: display)
            #expect(result == .needsVirtualDisplay(expected[preset]!), "\(preset)")
            #expect(ModeSelector.selectMode(for: preset, scaling: scaling, in: display.modes) == nil)
        }
    }

    @Test("4K is refused outright: the panel is smaller than the preset",
          arguments: ScalingPreference.allCases)
    func fourKIsRefusedOnASmallerPanel(scaling: ScalingPreference) {
        let result = ModeSelector.availability(of: .uhd2160, scaling: scaling, for: display)
        #expect(result == .unavailable(.exceedsPanel(panel: PixelSize(width: 2560, height: 1600))))
        if case .unavailable(let reason) = result {
            #expect(reason.message == "This display is 2560 × 1600")
        }
    }

    @Test("Without a default flag, Native falls back to the native-timing 2560x1600 mode")
    func defaultModeFallsBackToNativeTiming() {
        let mode = ModeSelector.defaultMode(in: display.modes)
        #expect(mode?.pixelSize == PixelSize(width: 2560, height: 1600))
        #expect(mode?.isNativeTiming == true)
    }

    @Test("The panel's own 1280x800 mode is the first step of the 16:10 ladder")
    func currentPresetIsTheSixteenByTenStep() {
        #expect(display.currentMode?.pointSize == PixelSize(width: 1280, height: 800))
        let current = ModeSelector.currentPreset(for: display, scaling: .hiDPI)
        #expect(current?.preset == .wxga800)
        #expect(current?.preset.aspect == .sixteenByTen)
    }

    @Test func nativePixelSizeMatchesFixture() {
        #expect(ModeSelector.nativePixelSize(from: display.modes) == display.nativePixelSize)
    }
}

@Suite("ModeSelector on a synthetic 1080p 60 Hz monitor")
struct External1080pTests {
    let display = try! FixtureLoader.display(.external1080p)

    @Test("1080p HiDPI falls back to the 1x mode with exactScaling false")
    func fullHDHiDPIFallsBackTo1x() {
        let result = ModeSelector.availability(of: .fullHD1080, scaling: .hiDPI, for: display)
        guard case .available(let mode, let exact) = result else {
            Issue.record("expected available, got \(result)")
            return
        }
        #expect(mode.id == 1)
        #expect(!mode.isHiDPI)
        #expect(!exact)
    }

    @Test func fullHDLowResolutionIsExact() {
        #expect(ModeSelector.availability(of: .fullHD1080, scaling: .lowResolution, for: display)
            == .available(display.modes[0], exactScaling: true))
    }

    @Test func hd720ResolvesTo1x() {
        #expect(ModeSelector.availability(of: .hd720, scaling: .lowResolution, for: display)
            == .available(display.modes[2], exactScaling: true))
        #expect(ModeSelector.availability(of: .hd720, scaling: .hiDPI, for: display)
            == .available(display.modes[2], exactScaling: false))
    }

    @Test("Presets larger than the 1080p panel are refused, not served by a virtual display")
    func largerPresetsAreRefused() {
        for preset in [ResolutionPreset.qhd1440, .uhd2160] {
            let result = ModeSelector.availability(of: preset, scaling: .hiDPI, for: display)
            #expect(result == .unavailable(.exceedsPanel(panel: PixelSize(width: 1920, height: 1080))),
                    "\(preset) should be refused on a 1080p panel")
        }
    }

    @Test("The 960x540 HiDPI mode is not mistaken for a 1080p HiDPI variant")
    func halfSizeHiDPIIsNotAPreset() {
        let half = display.modes[5]
        #expect(half.pixelSize == PixelSize(width: 1920, height: 1080))
        #expect(!ModeSelector.matches(half, preset: .fullHD1080, variant: .hiDPI))
        #expect(!ModeSelector.matches(half, preset: .fullHD1080, variant: .lowResolution))
    }

    @Test func defaultModeAndCurrentPreset() {
        #expect(ModeSelector.defaultMode(in: display.modes)?.id == 1)
        let current = ModeSelector.currentPreset(for: display, scaling: .hiDPI)
        #expect(current?.preset == .fullHD1080)
        #expect(current?.exact == false)
        #expect(ModeSelector.currentPreset(for: display, scaling: .lowResolution)?.exact == true)
    }
}
