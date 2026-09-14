import Testing
import ForceResCore

private let unsafeFlags = DisplayModeInfo.IOFlags.valid
private let safeFlags = DisplayModeInfo.IOFlags.valid | DisplayModeInfo.IOFlags.safe
private let nativeSafe = safeFlags | DisplayModeInfo.IOFlags.native

@Suite("ModeSelector refresh-rate ranking")
struct RefreshRankingTests {
    @Test func refreshRatesRoundingToTheSameHertzAreEqual() {
        #expect(ModeSelector.refreshRatesEqual(59.94, 60))
        #expect(ModeSelector.refreshRatesEqual(60, 59.94))
        #expect(ModeSelector.refreshRatesEqual(240, 240))
        #expect(ModeSelector.refreshRatesEqual(119.88, 120))
        #expect(!ModeSelector.refreshRatesEqual(59.4, 60))
        #expect(!ModeSelector.refreshRatesEqual(120, 240))
    }

    @Test("59.94 and 60 Hz tie, so the lower id wins")
    func nearEqualRatesTieOnID() {
        let modes = [mode(id: 7, 1920, 1080, hz: 60), mode(id: 3, 1920, 1080, hz: 59.94)]
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .lowResolution, in: modes)?.id == 3)
    }

    @Test("59.94 and 60 Hz tie, so native timing breaks the tie before id")
    func nearEqualRatesTieOnNativeTiming() {
        let modes = [mode(id: 3, 1920, 1080, hz: 59.94), mode(id: 7, 1920, 1080, hz: 60, flags: nativeSafe)]
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .lowResolution, in: modes)?.id == 7)
    }

    @Test("preferredModeIDs only breaks ties: rate, safe flag and native timing still come first")
    func preferredIDsOnlyBreakTies() {
        let twins = [mode(id: 3, 2560, 1440, hiDPI: true, hz: 240), mode(id: 5, 2560, 1440, hiDPI: true, hz: 240)]
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: twins)?.id == 3)
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: twins, preferredModeIDs: [5])?.id == 5)
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: twins, preferredModeIDs: [5, 3])?.id == 5)
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: twins, preferredModeIDs: [3, 5])?.id == 3)
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: twins, preferredModeIDs: [42])?.id == 3)

        let slowerPreferred = [mode(id: 3, 2560, 1440, hiDPI: true, hz: 240), mode(id: 5, 2560, 1440, hiDPI: true, hz: 120)]
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: slowerPreferred, preferredModeIDs: [5])?.id == 3)

        let unsafePreferred = [mode(id: 3, 2560, 1440, hiDPI: true, hz: 240),
                               mode(id: 5, 2560, 1440, hiDPI: true, hz: 240, flags: unsafeFlags)]
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: unsafePreferred, preferredModeIDs: [5])?.id == 3)

        let nativePreferred = [mode(id: 3, 2560, 1440, hiDPI: true, hz: 240, flags: nativeSafe),
                               mode(id: 5, 2560, 1440, hiDPI: true, hz: 240)]
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: nativePreferred, preferredModeIDs: [5])?.id == 3)
    }

    @Test func higherRateWinsRegardlessOfID() {
        let modes = [mode(id: 1, 1920, 1080, hz: 60), mode(id: 9, 1920, 1080, hz: 120), mode(id: 5, 1920, 1080, hz: 30)]
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .lowResolution, in: modes)?.id == 9)
    }

    @Test("A 0 Hz adaptive entry ranks equal to the maximum, not below 60 Hz")
    func adaptiveZeroHertzIsNotPenalized() {
        let modes = [mode(id: 2, 1920, 1080, hiDPI: true, hz: 60), mode(id: 1, 1920, 1080, hiDPI: true, hz: 0)]
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .hiDPI, in: modes)?.id == 1)
        let beatenByID = [mode(id: 1, 1920, 1080, hiDPI: true, hz: 120), mode(id: 4, 1920, 1080, hiDPI: true, hz: 0)]
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .hiDPI, in: beatenByID)?.id == 1)
        let onlyAdaptive = [mode(id: 8, 1920, 1080, hiDPI: true, hz: 0)]
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .hiDPI, in: onlyAdaptive)?.id == 8)
    }
}

@Suite("ModeSelector variant and safety rules")
struct VariantAndSafetyTests {
    @Test func hiDPIPreferredWhenBothVariantsExist() {
        let modes = [mode(id: 1, 1920, 1080), mode(id: 2, 1920, 1080, hiDPI: true)]
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .hiDPI, in: modes)?.id == 2)
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .lowResolution, in: modes)?.id == 1)
    }

    @Test("Low resolution falls back to HiDPI when only the 2x variant exists")
    func lowResolutionFallsBackToHiDPI() {
        let modes = [mode(id: 2, 1920, 1080, hiDPI: true)]
        let info = display(modes: modes)
        #expect(ModeSelector.availability(of: .fullHD1080, scaling: .lowResolution, for: info)
            == .available(modes[0], exactScaling: false))
    }

    @Test func interlacedAndStretchedModesAreExcluded() {
        let interlaced = mode(id: 1, 1920, 1080, hz: 120, flags: safeFlags | DisplayModeInfo.IOFlags.interlaced)
        let stretched = mode(id: 2, 1920, 1080, hz: 120, flags: safeFlags | DisplayModeInfo.IOFlags.stretched)
        let plain = mode(id: 3, 1920, 1080, hz: 60)
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .lowResolution, in: [interlaced, stretched, plain])?.id == 3)
        let onlyBad = display(modes: [interlaced, stretched])
        #expect(ModeSelector.availability(of: .fullHD1080, scaling: .lowResolution, for: onlyBad)
            == .unavailable(.onlyUnsafeModes))
    }

    @Test("Modes that are not usable for the desktop GUI are never selected")
    func unusableModesAreIgnored() {
        let unsafe = mode(id: 1, 2560, 1440, hz: 240, flags: unsafeFlags, gui: false)
        let safe = mode(id: 2, 2560, 1440, hz: 60)
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .lowResolution, in: [unsafe, safe])?.id == 2)
    }

    @Test("A preset whose only matching modes are unsafe is unavailable, not virtual")
    func unsafeOnlyIsUnavailable() {
        let modes = [mode(id: 1, 2560, 1440, hz: 240, flags: unsafeFlags, gui: false),
                     mode(id: 2, 1920, 1080, hz: 60, flags: nativeSafe)]
        let info = display(modes: modes)
        let result = ModeSelector.availability(of: .qhd1440, scaling: .hiDPI, for: info)
        #expect(result == .unavailable(.onlyUnsafeModes))
        if case .unavailable(let reason) = result {
            #expect(!reason.message.isEmpty)
        }
    }

    @Test func emptyModeListIsUnavailable() {
        let info = display(native: PixelSize(width: 1920, height: 1080), modes: [])
        #expect(ModeSelector.availability(of: .hd720, scaling: .hiDPI, for: info) == .unavailable(.noModes))
        #expect(ModeSelector.defaultMode(in: []) == nil)
    }

    @Test func virtualDisplayPlanLetterboxTolerance() {
        // 16:9 vs 16:10 differs by ~11%: letterboxed.
        let air = ModeSelector.virtualDisplayPlan(for: .fullHD1080, scaling: .hiDPI,
                                                  nativePixelSize: PixelSize(width: 2560, height: 1600))
        #expect(air.letterboxed && !air.exceedsPanel && air.hiDPI)
        // 3024x1964 (14" MacBook Pro) vs 16:9 differs by ~13%: letterboxed, 1x plan.
        let pro = ModeSelector.virtualDisplayPlan(for: .hd720, scaling: .lowResolution,
                                                  nativePixelSize: PixelSize(width: 3024, height: 1964))
        #expect(pro.letterboxed && !pro.exceedsPanel && !pro.hiDPI)
        // 1366x768 vs 16:9 differs by ~0.06%: within tolerance.
        let almost = ModeSelector.virtualDisplayPlan(for: .fullHD1080, scaling: .hiDPI,
                                                     nativePixelSize: PixelSize(width: 1366, height: 768))
        #expect(!almost.letterboxed && almost.exceedsPanel)
    }
}

@Suite("ModeSelector defaultMode and nativePixelSize")
struct DefaultAndNativeTests {
    @Test func defaultFlagWinsEvenWhenOtherModesAreFaster() {
        let modes = [mode(id: 1, 3840, 2160, hz: 240, flags: nativeSafe),
                     mode(id: 2, 1920, 1080, hiDPI: true, hz: 60, flags: safeFlags | DisplayModeInfo.IOFlags.default)]
        #expect(ModeSelector.defaultMode(in: modes)?.id == 2)
    }

    @Test func withoutDefaultFlagPrefersSafeHiDPINativeTiming() {
        let modes = [mode(id: 1, 3840, 2160, hz: 240, flags: nativeSafe),
                     mode(id: 2, 1920, 1080, hiDPI: true, hz: 120, flags: nativeSafe),
                     mode(id: 3, 1920, 1080, hiDPI: true, hz: 240, flags: nativeSafe),
                     mode(id: 4, 1920, 1080, hiDPI: true, hz: 240, flags: unsafeFlags, gui: false)]
        #expect(ModeSelector.defaultMode(in: modes)?.id == 3)
    }

    @Test func withoutNativeTimingPrefersLargestSafePixelSize() {
        let modes = [mode(id: 1, 1280, 720, hz: 240), mode(id: 2, 2560, 1440, hz: 60), mode(id: 3, 2560, 1440, hz: 120),
                     mode(id: 4, 3840, 2160, hz: 240, flags: unsafeFlags, gui: false)]
        #expect(ModeSelector.defaultMode(in: modes)?.id == 3)
    }

    @Test func nativePixelSizeUsesNativeFlagThenLargest1x() {
        let flagged = [mode(id: 1, 1920, 1080, hiDPI: true, flags: nativeSafe), mode(id: 2, 5120, 2880)]
        #expect(ModeSelector.nativePixelSize(from: flagged) == PixelSize(width: 3840, height: 2160))
        let unflagged = [mode(id: 1, 1680, 1050, hiDPI: true), mode(id: 2, 2560, 1600), mode(id: 3, 1440, 900)]
        #expect(ModeSelector.nativePixelSize(from: unflagged) == PixelSize(width: 2560, height: 1600))
        let onlyHiDPI = [mode(id: 1, 1280, 800, hiDPI: true)]
        #expect(ModeSelector.nativePixelSize(from: onlyHiDPI) == PixelSize(width: 2560, height: 1600))
        #expect(ModeSelector.nativePixelSize(from: []) == PixelSize(width: 0, height: 0))
    }

    @Test func currentPresetRecognisesEachVariant() {
        let modes = [mode(id: 1, 1280, 720), mode(id: 2, 1280, 720, hiDPI: true),
                     mode(id: 3, 1440, 900), mode(id: 4, 1152, 864)]
        #expect(ModeSelector.currentPreset(for: display(modes: modes, current: 1), scaling: .hiDPI)?.exact == false)
        #expect(ModeSelector.currentPreset(for: display(modes: modes, current: 2), scaling: .hiDPI)?.exact == true)
        #expect(ModeSelector.currentPreset(for: display(modes: modes, current: 2), scaling: .hiDPI)?.preset == .hd720)
        // 1440x900 is the 16:10 ladder's second step; 1152x864 belongs to no shape.
        #expect(ModeSelector.currentPreset(for: display(modes: modes, current: 3), scaling: .hiDPI)?.preset == .hdPlus900)
        #expect(ModeSelector.currentPreset(for: display(modes: modes, current: 4), scaling: .hiDPI) == nil)
        #expect(ModeSelector.currentPreset(for: display(modes: modes, current: nil), scaling: .hiDPI) == nil)
    }
}
