import Foundation
import Testing
import ForceResCore

@Suite("Refresh preference on the M4 + Odyssey G80SD dump")
struct OdysseyRefreshTests {
    let display = try! FixtureLoader.display(.m4OdysseyG80SD)
    /// The same dump with every unclassified entry recorded as fixed (see `FixtureLoader.classified`).
    let classified = FixtureLoader.classified(try! FixtureLoader.display(.m4OdysseyG80SD))

    @Test func fixtureRecordsTheVariableTwinsAndTheRange() throws {
        #expect(display.variableRefreshRange == 48...240)
        for id: Int32 in [133, 102, 104, 135, 163, 41, 43, 47] {
            #expect(display.modes.first { $0.id == id }?.isVariableRefresh == true, "\(id)")
        }
        for id: Int32 in [132, 103, 105, 134, 162, 44, 42, 48] {
            #expect(display.modes.first { $0.id == id }?.isVariableRefresh == false, "\(id)")
        }
        #expect(display.modes.first { $0.id == 136 }?.isVariableRefresh != true)
        #expect(display.modes.first { $0.id == 136 }?.roundedRefreshRate == 120)
    }

    @Test("highest picks the variable twin 133 for 1440p HiDPI")
    func highestPrefersTheVariableTwin() throws {
        let selection = try #require(ModeSelector.select(for: .qhd1440, scaling: .hiDPI, in: display.modes))
        #expect(selection.mode.id == 133)
        #expect(selection.exactScaling)
        #expect(selection.refreshOutcome == .exact)
    }

    @Test("fixed rates pick the fixed entry at that rate",
          arguments: [(240, Int32(132)), (120, 136), (60, 139), (30, 141)])
    func fixedRatesResolve(hertz: Int, expectedID: Int32) throws {
        let selection = try #require(ModeSelector.select(for: .qhd1440, scaling: .hiDPI, in: classified.modes,
                                                         refresh: .fixed(hertz: hertz)))
        #expect(selection.mode.id == expectedID)
        #expect(selection.mode.roundedRefreshRate == hertz)
        #expect(selection.mode.isAdaptiveRefresh != true)
        #expect(selection.exactScaling)
        #expect(selection.refreshOutcome == .exact)
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: display.modes,
                                        refresh: .fixed(hertz: hertz))?.id == expectedID)
        #expect(ModeSelector.availability(of: .qhd1440, scaling: .hiDPI, for: classified, refresh: .fixed(hertz: hertz))
            == .available(selection.mode, exactScaling: true))
    }

    @Test("a rate the display does not enumerate (144) falls back to highest and says so")
    func unlistedFixedRateFallsBack() throws {
        let selection = try #require(ModeSelector.select(for: .qhd1440, scaling: .hiDPI, in: classified.modes,
                                                         refresh: .fixed(hertz: 144)))
        #expect(selection.mode.id == 133)
        #expect(selection.refreshOutcome == .fellBackToHighest)
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: display.modes,
                                        refresh: .fixed(hertz: 144))?.id == 133)
    }

    @Test func variablePicksTheVariableTwinAtTheTopRate() throws {
        let selection = try #require(ModeSelector.select(for: .qhd1440, scaling: .hiDPI, in: classified.modes,
                                                         refresh: .variable))
        #expect(selection.mode.id == 133)
        #expect(selection.refreshOutcome == .exact)
        // 720p 1x has variable entries at 240 (43) and 60 (47); the top rate wins.
        #expect(ModeSelector.selectMode(for: .hd720, scaling: .lowResolution, in: display.modes,
                                        refresh: .variable)?.id == 43)
    }

    @Test("variable on a family without a classified twin picks the best entry but is unverified")
    func variableIsUnverifiedWhenNoTwinIsKnown() throws {
        let selection = try #require(ModeSelector.select(for: .qhd1440, scaling: .hiDPI, in: unclassifiedModes,
                                                         refresh: .variable))
        #expect(selection.mode.id == 132)
        #expect(selection.refreshOutcome == .unverified)
    }

    /// The dump with the classifier's answers erased, the shape a snapshot has when SkyLight's
    /// private symbols do not resolve.
    var unclassifiedModes: [DisplayModeInfo] {
        display.modes.map { mode in
            var mode = mode
            mode.isVariableRefresh = nil
            mode.isProMotion = nil
            return mode
        }
    }

    @Test("fixed and variable requests on an unclassified family are unverified; highest never is")
    func unclassifiedFamiliesReportUnverified() throws {
        let fixed = try #require(ModeSelector.select(for: .qhd1440, scaling: .hiDPI, in: unclassifiedModes,
                                                     refresh: .fixed(hertz: 240)))
        #expect(fixed.mode.id == 132 && fixed.refreshOutcome == .unverified)
        let missing = try #require(ModeSelector.select(for: .qhd1440, scaling: .hiDPI, in: unclassifiedModes,
                                                       refresh: .fixed(hertz: 144)))
        #expect(missing.mode.id == 132 && missing.refreshOutcome == .unverified)
        let highest = try #require(ModeSelector.select(for: .qhd1440, scaling: .hiDPI, in: unclassifiedModes))
        #expect(highest.mode.id == 132 && highest.refreshOutcome == .exact)
        // One unclassified entry anywhere in the family is enough, even at a rate with no twin.
        var partial = classified.modes
        let index139 = try #require(partial.firstIndex { $0.id == 139 })
        partial[index139].isVariableRefresh = nil
        partial[index139].isProMotion = nil
        #expect(ModeSelector.select(for: .qhd1440, scaling: .hiDPI, in: partial,
                                    refresh: .fixed(hertz: 240))?.refreshOutcome == .unverified)
        #expect(ModeSelector.select(for: .qhd1440, scaling: .hiDPI, in: partial,
                                    refresh: .fixed(hertz: 240))?.mode.id == 132)
    }

    @Test("a ProMotion flag counts as adaptive when the VRR classifier said nothing")
    func proMotionCountsAsAdaptive() throws {
        var modes = unclassifiedModes
        let index = try #require(modes.firstIndex { $0.id == 133 })
        modes[index].isProMotion = true
        #expect(modes[index].isAdaptiveRefresh == true)
        #expect(modes[index].isVariableRefresh == nil)
        let selection = try #require(ModeSelector.select(for: .qhd1440, scaling: .hiDPI, in: modes, refresh: .variable))
        #expect(selection.mode.id == 133)
        // The rest of the family is still unclassified, so the outcome stays unverified…
        #expect(selection.refreshOutcome == .unverified)
        // …but the option list may offer Variable, because one entry is positively adaptive.
        var d = display
        d.modes = modes
        #expect(ModeSelector.availableRefreshOptions(for: .qhd1440, scaling: .hiDPI, in: d).first
            == .variable(minHertz: 48, maxHertz: 240))
        d.currentModeID = 133
        #expect(ModeSelector.currentRefreshOption(for: d) == .variable(minHertz: 48, maxHertz: 240))
        // A classifier answer wins over the ProMotion flag.
        var both = modes[index]
        both.isVariableRefresh = false
        #expect(both.isAdaptiveRefresh == false)
        both.isVariableRefresh = true
        both.isProMotion = false
        #expect(both.isAdaptiveRefresh == true)
    }

    @Test("the refresh preference applies within the scaling fallback variant")
    func refreshAppliesAfterScalingFallback() throws {
        // 4K HiDPI does not exist; 4K 1x @ 120 is mode 164.
        let selection = try #require(ModeSelector.select(for: .uhd2160, scaling: .hiDPI, in: classified.modes,
                                                         refresh: .fixed(hertz: 120)))
        #expect(selection.mode.id == 164)
        #expect(!selection.exactScaling)
        #expect(selection.refreshOutcome == .exact)
    }

    @Test func optionsFor1440pHiDPI() {
        let options = ModeSelector.availableRefreshOptions(for: .qhd1440, scaling: .hiDPI, in: display)
        #expect(options == [.variable(minHertz: 48, maxHertz: 240), .fixed(hertz: 240), .fixed(hertz: 120),
                            .fixed(hertz: 60), .fixed(hertz: 30)])
    }

    @Test func optionsFollowTheScalingFallback() {
        // 4K HiDPI has no modes, so the 1x family (163 variable, 240/120/60/30) is offered.
        let options = ModeSelector.availableRefreshOptions(for: .uhd2160, scaling: .hiDPI, in: display)
        #expect(options == [.variable(minHertz: 48, maxHertz: 240), .fixed(hertz: 240), .fixed(hertz: 120),
                            .fixed(hertz: 60), .fixed(hertz: 30)])
    }

    @Test("with no preset the current mode's own family is offered")
    func optionsForTheCurrentModeFamily() {
        // Fixture current mode is 133 (1440p HiDPI).
        let native = ModeSelector.availableRefreshOptions(for: nil, scaling: .hiDPI, in: display)
        #expect(native == ModeSelector.availableRefreshOptions(for: .qhd1440, scaling: .hiDPI, in: display))
        // The current mode's own family: 104 is 1080p 1x.
        var at104 = display
        at104.currentModeID = 104
        let oneX = ModeSelector.availableRefreshOptions(for: nil, scaling: .hiDPI, in: at104)
        #expect(oneX == ModeSelector.availableRefreshOptions(for: .fullHD1080, scaling: .lowResolution, in: display))
        #expect(oneX.first == .variable(minHertz: 48, maxHertz: 240))
        var unknown = display
        unknown.currentModeID = nil
        #expect(ModeSelector.availableRefreshOptions(for: nil, scaling: .hiDPI, in: unknown).isEmpty)
        unknown.currentModeID = 9999
        #expect(ModeSelector.availableRefreshOptions(for: nil, scaling: .hiDPI, in: unknown).isEmpty)
    }

    @Test("Variable is only offered when an entry is classified adaptive")
    func variableOptionNeedsAClassifiedEntry() {
        var d = display
        d.modes = unclassifiedModes
        #expect(ModeSelector.availableRefreshOptions(for: .qhd1440, scaling: .hiDPI, in: d)
            == [.fixed(hertz: 240), .fixed(hertz: 120), .fixed(hertz: 60), .fixed(hertz: 30)])
        #expect(ModeSelector.availableRefreshOptions(for: nil, scaling: .hiDPI, in: d)
            == [.fixed(hertz: 240), .fixed(hertz: 120), .fixed(hertz: 60), .fixed(hertz: 30)])
        #expect(ModeSelector.availableRefreshOptions(for: .qhd1440, scaling: .hiDPI, in: classified).first
            == .variable(minHertz: 48, maxHertz: 240))
    }

    @Test func currentRefreshOptionFollowsTheCurrentMode() {
        var display = display
        display.currentModeID = 132
        #expect(ModeSelector.currentRefreshOption(for: display) == .fixed(hertz: 240))
        display.currentModeID = 133
        #expect(ModeSelector.currentRefreshOption(for: display) == .variable(minHertz: 48, maxHertz: 240))
        display.currentModeID = 136
        #expect(ModeSelector.currentRefreshOption(for: display) == .fixed(hertz: 120))
        display.currentModeID = nil
        #expect(ModeSelector.currentRefreshOption(for: display) == nil)
    }

    @Test("an unclassified current mode with a twin at its rate cannot be named")
    func currentRefreshOptionIsNilForAnUnclassifiedTwin() {
        var d = display
        d.modes = unclassifiedModes
        d.currentModeID = 132   // twin 133 at 240 Hz
        #expect(ModeSelector.currentRefreshOption(for: d) == nil)
        d.currentModeID = 133
        #expect(ModeSelector.currentRefreshOption(for: d) == nil)
        d.currentModeID = 136   // the only 120 Hz entry: no twin, so 120 is certain
        #expect(ModeSelector.currentRefreshOption(for: d) == .fixed(hertz: 120))
        // A classified current mode is named even when its twin is not.
        var oneSided = d
        oneSided.modes[oneSided.modes.firstIndex { $0.id == 132 }!].isVariableRefresh = false
        oneSided.currentModeID = 132
        #expect(ModeSelector.currentRefreshOption(for: oneSided) == .fixed(hertz: 240))
    }

    // MARK: Family-anchored selection (the "Native" refresh control)

    @Test("select(inFamilyOf:) matches the preset route for 1440p HiDPI")
    func familySelectionMatchesThePresetRoute() throws {
        let anchor = try #require(classified.modes.first { $0.id == 132 })
        let modes = classified.modes
        let highest = try #require(ModeSelector.select(inFamilyOf: anchor, in: modes, refresh: .highest))
        #expect(highest.mode.id == 133 && highest.refreshOutcome == .exact && highest.exactScaling)
        #expect(ModeSelector.select(inFamilyOf: anchor, in: modes, refresh: .fixed(hertz: 240))?.mode.id == 132)
        #expect(ModeSelector.select(inFamilyOf: anchor, in: modes, refresh: .fixed(hertz: 120))?.mode.id == 136)
        #expect(ModeSelector.select(inFamilyOf: anchor, in: modes, refresh: .fixed(hertz: 60))?.mode.id == 139)
        #expect(ModeSelector.select(inFamilyOf: anchor, in: modes, refresh: .variable)?.mode.id == 133)
        let missing = try #require(ModeSelector.select(inFamilyOf: anchor, in: modes, refresh: .fixed(hertz: 144)))
        #expect(missing.mode.id == 133 && missing.refreshOutcome == .fellBackToHighest)
        for refresh in [RefreshPreference.highest, .fixed(hertz: 60), .fixed(hertz: 144), .variable] {
            #expect(ModeSelector.select(inFamilyOf: anchor, in: modes, preferredModeIDs: [132], refresh: refresh)
                == ModeSelector.select(for: .qhd1440, scaling: .hiDPI, in: modes, preferredModeIDs: [132], refresh: refresh))
        }
        // Anchoring on any family member, usable or not, gives the same family.
        let anchor141 = try #require(modes.first { $0.id == 141 })
        #expect(ModeSelector.select(inFamilyOf: anchor141, in: modes, refresh: .highest)?.mode.id == 133)
        #expect(ModeSelector.select(inFamilyOf: anchor, in: [], refresh: .highest) == nil)
        // Unclassified families are unverified here too.
        let raw = try #require(ModeSelector.select(inFamilyOf: anchor, in: unclassifiedModes, refresh: .fixed(hertz: 240)))
        #expect(raw.mode.id == 132 && raw.refreshOutcome == .unverified)
        #expect(ModeSelector.select(inFamilyOf: anchor, in: unclassifiedModes, refresh: .highest)?.refreshOutcome == .exact)
    }

    @Test("a family of unsafe modes only has no pick")
    func familySelectionIgnoresUnusableModes() {
        let unsafe = [mode(id: 1, 1920, 1080, hiDPI: true, hz: 60, flags: DisplayModeInfo.IOFlags.valid, gui: false),
                      mode(id: 2, 1920, 1080, hiDPI: true, hz: 120, flags: DisplayModeInfo.IOFlags.valid, gui: false),
                      mode(id: 3, 1920, 1080, hiDPI: false, hz: 60)]
        #expect(ModeSelector.select(inFamilyOf: unsafe[0], in: unsafe, refresh: .highest) == nil)
        #expect(ModeSelector.select(inFamilyOf: unsafe[2], in: unsafe, refresh: .highest)?.mode.id == 3)
    }

    @Test func isSatisfiedFollowsThePreference() throws {
        let modes = classified.modes
        func m(_ id: Int32) -> DisplayModeInfo { modes.first { $0.id == id }! }
        let anchor = m(132)
        let highest = try #require(ModeSelector.select(inFamilyOf: anchor, in: modes, refresh: .highest))
        // .highest: any family member at the top rate, whichever twin.
        #expect(ModeSelector.isSatisfied(current: m(133), by: highest, refresh: .highest))
        #expect(ModeSelector.isSatisfied(current: m(132), by: highest, refresh: .highest))
        #expect(!ModeSelector.isSatisfied(current: m(136), by: highest, refresh: .highest))
        #expect(!ModeSelector.isSatisfied(current: m(102), by: highest, refresh: .highest), "1080p HiDPI is another family")
        // .fixed: the rate on a non-adaptive entry.
        let fixed240 = try #require(ModeSelector.select(inFamilyOf: anchor, in: modes, refresh: .fixed(hertz: 240)))
        #expect(ModeSelector.isSatisfied(current: m(132), by: fixed240, refresh: .fixed(hertz: 240)))
        #expect(!ModeSelector.isSatisfied(current: m(133), by: fixed240, refresh: .fixed(hertz: 240)))
        #expect(!ModeSelector.isSatisfied(current: m(136), by: fixed240, refresh: .fixed(hertz: 240)))
        let fixed120 = try #require(ModeSelector.select(inFamilyOf: anchor, in: modes, refresh: .fixed(hertz: 120)))
        #expect(ModeSelector.isSatisfied(current: m(136), by: fixed120, refresh: .fixed(hertz: 120)))
        #expect(!ModeSelector.isSatisfied(current: m(139), by: fixed120, refresh: .fixed(hertz: 120)))
        // .variable: an adaptive entry.
        let variable = try #require(ModeSelector.select(inFamilyOf: anchor, in: modes, refresh: .variable))
        #expect(ModeSelector.isSatisfied(current: m(133), by: variable, refresh: .variable))
        #expect(!ModeSelector.isSatisfied(current: m(132), by: variable, refresh: .variable))
        // A request that fell back to highest is judged by the highest rule, so it never churns.
        let missing = try #require(ModeSelector.select(inFamilyOf: anchor, in: modes, refresh: .fixed(hertz: 144)))
        #expect(missing.refreshOutcome == .fellBackToHighest)
        #expect(ModeSelector.isSatisfied(current: m(133), by: missing, refresh: .fixed(hertz: 144)))
        #expect(ModeSelector.isSatisfied(current: m(132), by: missing, refresh: .fixed(hertz: 144)))
        #expect(!ModeSelector.isSatisfied(current: m(136), by: missing, refresh: .fixed(hertz: 144)))
        // Unverified picks likewise: a 240 Hz twin is left alone, a different rate is not.
        let unverified = try #require(ModeSelector.select(inFamilyOf: anchor, in: unclassifiedModes, refresh: .fixed(hertz: 240)))
        #expect(unverified.refreshOutcome == .unverified)
        #expect(ModeSelector.isSatisfied(current: m(133), by: unverified, refresh: .fixed(hertz: 240)))
        #expect(!ModeSelector.isSatisfied(current: m(136), by: unverified, refresh: .fixed(hertz: 240)))
        // The target's own id is always satisfied; a non-GUI-usable current never is.
        var unsafe = m(132)
        unsafe.isUsableForDesktopGUI = false
        #expect(!ModeSelector.isSatisfied(current: unsafe, by: highest, refresh: .highest))
        #expect(ModeSelector.isSatisfied(current: highest.mode, by: highest, refresh: .fixed(hertz: 240)),
                "the target's own id (133) is satisfied even though 133 is the variable twin")
    }

    @Test("isSatisfied: 0 Hz counts as the maximum and 59.94 equals 60")
    func isSatisfiedRateTolerance() {
        var adaptive = mode(id: 4, 1920, 1080, hiDPI: true, hz: 0)
        adaptive.isProMotion = true
        let modes = [mode(id: 1, 1920, 1080, hiDPI: true, hz: 59.94), mode(id: 2, 1920, 1080, hiDPI: true, hz: 60),
                     mode(id: 3, 1920, 1080, hiDPI: true, hz: 120), adaptive]
        let highest = ModeSelection(mode: modes[2], exactScaling: true, refreshOutcome: .exact)
        #expect(ModeSelector.isSatisfied(current: adaptive, by: highest, refresh: .highest))
        #expect(!ModeSelector.isSatisfied(current: modes[0], by: highest, refresh: .highest))
        let sixty = ModeSelection(mode: modes[1], exactScaling: true, refreshOutcome: .exact)
        #expect(ModeSelector.isSatisfied(current: modes[0], by: sixty, refresh: .highest))
        #expect(ModeSelector.isSatisfied(current: modes[0], by: sixty, refresh: .fixed(hertz: 60)))
        let variable = ModeSelection(mode: adaptive, exactScaling: true, refreshOutcome: .exact)
        #expect(ModeSelector.isSatisfied(current: modes[2], by: variable, refresh: .highest))
        #expect(!ModeSelector.isSatisfied(current: modes[2], by: variable, refresh: .variable))
    }

    @Test func refreshOptionOfAMode() throws {
        let modes = classified.modes
        #expect(ModeSelector.refreshOption(of: try #require(modes.first { $0.id == 133 }), range: 48...240)
            == .variable(minHertz: 48, maxHertz: 240))
        #expect(ModeSelector.refreshOption(of: try #require(modes.first { $0.id == 133 }), range: nil)
            == .variable(minHertz: nil, maxHertz: nil))
        #expect(ModeSelector.refreshOption(of: try #require(modes.first { $0.id == 132 }), range: 48...240) == .fixed(hertz: 240))
        #expect(ModeSelector.refreshOption(of: try #require(modes.first { $0.id == 139 }), range: nil) == .fixed(hertz: 60))
        #expect(ModeSelector.refreshOption(of: mode(id: 1, 1920, 1080, hz: 59.94), range: nil) == .fixed(hertz: 60))
        var proMotion = mode(id: 2, 1512, 982, hiDPI: true, hz: 120)
        proMotion.isProMotion = true
        #expect(ModeSelector.refreshOption(of: proMotion, range: nil) == .variable(minHertz: nil, maxHertz: nil))
        #expect(ModeSelector.refreshOption(of: mode(id: 3, 1920, 1080, hz: 0), range: nil) == .fixed(hertz: 0))
        // currentRefreshOption is the same answer for the display's current mode…
        var d = classified
        d.currentModeID = 139
        #expect(ModeSelector.currentRefreshOption(for: d)
            == ModeSelector.refreshOption(of: try #require(d.currentMode), range: d.variableRefreshRange))
        // …except that an unclassified 0 Hz current mode stays nil there.
        #expect(ModeSelector.currentRefreshOption(for: ForceResCoreTests.display(modes: [mode(id: 3, 1920, 1080, hz: 0)], current: 3)) == nil)
    }
}

@Suite("Refresh options on other fixtures")
struct OtherFixtureRefreshTests {
    @Test func macBookAirOffersOnly60() throws {
        let display = try FixtureLoader.display(.m1MacBookAir)
        #expect(display.variableRefreshRange == nil)
        #expect(ModeSelector.availableRefreshOptions(for: nil, scaling: .hiDPI, in: display) == [.fixed(hertz: 60)])
        #expect(ModeSelector.currentRefreshOption(for: display) == .fixed(hertz: 60))
        #expect(ModeSelector.availableRefreshOptions(for: .fullHD1080, scaling: .hiDPI, in: display).isEmpty)
    }

    @Test func external1080pOffersOnly60() throws {
        let display = try FixtureLoader.display(.external1080p)
        #expect(ModeSelector.availableRefreshOptions(for: .fullHD1080, scaling: .hiDPI, in: display) == [.fixed(hertz: 60)])
    }

    @Test("synthetic: 59.94 and 60 collapse to one option, 0 Hz adds none, variable without a range")
    func syntheticRatesDedupeAndSort() {
        var adaptive = mode(id: 4, 1920, 1080, hiDPI: true, hz: 0)
        adaptive.isVariableRefresh = true
        let modes = [mode(id: 1, 1920, 1080, hiDPI: true, hz: 59.94), mode(id: 2, 1920, 1080, hiDPI: true, hz: 60),
                     mode(id: 3, 1920, 1080, hiDPI: true, hz: 120), adaptive,
                     mode(id: 5, 1920, 1080, hiDPI: true, hz: 48, gui: false)]
        let d = display(modes: modes, current: 4)
        #expect(ModeSelector.availableRefreshOptions(for: .fullHD1080, scaling: .hiDPI, in: d)
            == [.variable(minHertz: nil, maxHertz: nil), .fixed(hertz: 120), .fixed(hertz: 60)])
        #expect(ModeSelector.currentRefreshOption(for: d) == .variable(minHertz: nil, maxHertz: nil))
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .hiDPI, in: modes, refresh: .fixed(hertz: 60))?.id == 1)
        #expect(ModeSelector.selectMode(for: .fullHD1080, scaling: .hiDPI, in: modes, refresh: .variable)?.id == 4)
    }
}

@Suite("Refresh JSON stability")
struct RefreshCodingTests {
    private func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func refreshPreferenceEncoding() throws {
        #expect(try encode(RefreshPreference.highest) == #"{"kind":"highest"}"#)
        #expect(try encode(RefreshPreference.fixed(hertz: 60)) == #"{"hertz":60,"kind":"fixed"}"#)
        #expect(try encode(RefreshPreference.variable) == #"{"kind":"variable"}"#)
        for preference in [RefreshPreference.highest, .fixed(hertz: 120), .variable] {
            #expect(try decode(RefreshPreference.self, try encode(preference)) == preference)
        }
        #expect(throws: DecodingError.self) { try decode(RefreshPreference.self, #"{"kind":"fixed"}"#) }
        #expect(throws: DecodingError.self) { try decode(RefreshPreference.self, #"{"kind":"turbo"}"#) }
        #expect(RefreshPreference.fixed(hertz: 60).debugDescription == "fixed(60 Hz)")
    }

    @Test func refreshOptionEncoding() throws {
        #expect(try encode(RefreshOption.fixed(hertz: 120)) == #"{"hertz":120,"kind":"fixed"}"#)
        #expect(try encode(RefreshOption.variable(minHertz: 48, maxHertz: 240))
            == #"{"kind":"variable","maxHertz":240,"minHertz":48}"#)
        #expect(try encode(RefreshOption.variable(minHertz: nil, maxHertz: nil)) == #"{"kind":"variable"}"#)
        for option in [RefreshOption.fixed(hertz: 30), .variable(minHertz: 48, maxHertz: 240), .variable(minHertz: nil, maxHertz: nil)] {
            #expect(try decode(RefreshOption.self, try encode(option)) == option)
        }
        #expect(RefreshOption.variable(minHertz: 48, maxHertz: 240).preference == .variable)
        #expect(RefreshOption.fixed(hertz: 60).preference == .fixed(hertz: 60))
    }

    @Test func displayChoiceOmitsHighestAndDecodesWithoutRefresh() throws {
        let plain = DisplayChoice(preset: .fullHD1080, scaling: .hiDPI)
        #expect(plain.refresh == .highest)
        #expect(try encode(plain) == #"{"preset":"fullHD1080","scaling":"hiDPI"}"#)
        #expect(try decode(DisplayChoice.self, #"{"preset":"fullHD1080","scaling":"hiDPI"}"#) == plain)

        let fixed = DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 120))
        #expect(try encode(fixed) == #"{"preset":"qhd1440","refresh":{"hertz":120,"kind":"fixed"},"scaling":"hiDPI"}"#)
        #expect(try decode(DisplayChoice.self, try encode(fixed)) == fixed)

        let native = DisplayChoice(preset: nil, scaling: .lowResolution, refresh: .variable)
        #expect(try encode(native) == #"{"refresh":{"kind":"variable"},"scaling":"lowResolution"}"#)
        #expect(try decode(DisplayChoice.self, try encode(native)) == native)
    }

    @Test func displayChoicePersistsRefreshThroughTheStores() throws {
        let scratch = try ScratchDefaults()
        let store = UserDefaultsPreferencesStore(defaults: scratch.defaults)
        let choice = DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 60))
        store.setChoice(choice, forDisplayID: "uuid-1")
        #expect(UserDefaultsPreferencesStore(defaults: scratch.defaults).choice(forDisplayID: "uuid-1") == choice)
        let memory = InMemoryPreferencesStore()
        memory.setChoice(choice, forDisplayID: "uuid-1")
        #expect(memory.choice(forDisplayID: "uuid-1")?.refresh == .fixed(hertz: 60))
    }

    @Test func modeAndDisplayFieldsRoundTripAndDefaultToNil() throws {
        var mode = mode(id: 1, 1920, 1080, hz: 60)
        #expect(mode.isVariableRefresh == nil && mode.isProMotion == nil)
        #expect(!(try encode(mode)).contains("isVariableRefresh"))
        mode.isVariableRefresh = true
        mode.isProMotion = false
        #expect(try decode(DisplayModeInfo.self, try encode(mode)) == mode)

        var display = display(modes: [mode], current: 1)
        #expect(display.variableRefreshRange == nil)
        let bare = try encode(display)
        #expect(!bare.contains("minHertz"))
        display.variableRefreshRange = 48...240
        let json = try encode(display)
        #expect(json.contains(#""maxHertz":240"#) && json.contains(#""minHertz":48"#))
        #expect(try decode(DisplayInfo.self, json) == display)
        // A malformed range (max below min) decodes as unknown rather than failing the display.
        let broken = json.replacingOccurrences(of: #""maxHertz":240"#, with: #""maxHertz":10"#)
        #expect(try decode(DisplayInfo.self, broken).variableRefreshRange == nil)
    }

    @Test func odysseyFixtureRoundTripsWithTheNewFields() throws {
        let snapshot = try FixtureLoader.snapshot(.m4OdysseyG80SD)
        let again = try DisplaySnapshot.decode(from: try snapshot.encodedJSON())
        #expect(again.displays == snapshot.displays)
        #expect(again.displays.first?.variableRefreshRange == 48...240)
    }
}
