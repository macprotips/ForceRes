import Foundation
import ForceResCore
import ForceResDisplay
import Testing
@testable import ForceRes

/// Refresh-rate control on the Odyssey G80SD dump: 1440p HiDPI lists 132 (fixed 240), 133
/// (variable 240, the recorded current mode), 136 (120), 139 (60), 141 (30); the 1x family
/// lists 134/135/137/138/140.
@Suite("Refresh rate: satisfied means satisfied")
@MainActor
struct RefreshSatisfiedTests {
    let odyssey = try! Fixtures.display(.m4OdysseyG80SD)

    private func onMode(_ id: Int32) -> DisplayInfo {
        var display = odyssey
        display.currentModeID = id
        return display
    }

    @Test("selecting the preset in effect changes nothing on either twin", arguments: [Int32(132), 133])
    func selectingTheCurrentFamilyIsANoOp(currentID: Int32) {
        let h = Harness(displays: [onMode(currentID)])
        h.model.select(preset: .qhd1440, for: h.display)
        #expect(h.service.applied.isEmpty)
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.store.choice(forDisplayID: odyssey.id) == DisplayChoice(preset: .qhd1440, scaling: .hiDPI))
        #expect(h.model.tileState(.qhd1440, for: h.display).isSelected)
        #expect(h.model.isSatisfied(h.display, by: DisplayChoice(preset: .qhd1440, scaling: .hiDPI)))
    }

    @Test("reconcile leaves a highest choice alone on either twin", arguments: [Int32(132), 133])
    func reconcileDoesNotChurnBetweenTwins(currentID: Int32) {
        let h = Harness(displays: [onMode(currentID)])
        h.store.setChoice(DisplayChoice(preset: .qhd1440, scaling: .hiDPI), forDisplayID: odyssey.id)
        h.model.reconcile()
        h.now = h.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        h.model.reconcile()
        #expect(h.service.applied.isEmpty)
    }

    @Test func aLowerRateDoesNotSatisfyHighest() {
        // Highest means the top rate: 60 Hz in the 1440p family is the right family, wrong rate.
        let h = Harness(displays: [onMode(139)])
        #expect(!h.model.isSatisfied(h.display, by: DisplayChoice(preset: .qhd1440, scaling: .hiDPI)))
        #expect(h.model.isSatisfied(h.display, by: DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 60))))
        #expect(!h.model.isSatisfied(h.display, by: DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 120))))
        #expect(!h.model.isSatisfied(h.display, by: DisplayChoice(preset: .qhd1440, scaling: .lowResolution)))
        #expect(!h.model.isSatisfied(h.display, by: DisplayChoice(preset: .fullHD1080, scaling: .hiDPI)))
    }

    @Test func reconcileRestoresTheTopRateWhenItDroppedExternally() {
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: .qhd1440, scaling: .hiDPI), forDisplayID: odyssey.id)
        h.model.reconcile()
        #expect(h.service.applied.isEmpty)
        // Something else drops the display to 60 Hz; the saved highest is silently restored.
        _ = try? h.service.apply(modeID: 139, to: odyssey.id, persistence: .session)
        h.model.refresh()
        h.model.reconcile()
        #expect(h.service.applied.last == Applied(133, odyssey.id, .permanent))
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.model.refreshFallbackNote(for: h.display) == nil)
    }

    @Test func explicitPreferencesDistinguishTheTwins() {
        let fixed = Harness(displays: [onMode(132)])
        #expect(fixed.model.isSatisfied(fixed.display, by: DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 240))))
        #expect(!fixed.model.isSatisfied(fixed.display, by: DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .variable)))
        let variable = Harness(displays: [onMode(133)])
        #expect(variable.model.isSatisfied(variable.display, by: DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .variable)))
        #expect(!variable.model.isSatisfied(variable.display, by: DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 240))))
    }

    @Test func selectingVariableWhileAlreadyVariableOnlyRecordsTheChoice() {
        let h = Harness(displays: [onMode(133)])
        h.model.select(refresh: .variable, for: h.display)
        #expect(h.service.applied.isEmpty)
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.store.choice(forDisplayID: odyssey.id) == DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .variable))
    }
}

@Suite("Refresh rate: select, keep, revert, reconcile")
@MainActor
struct RefreshSelectTests {
    let odyssey = try! Fixtures.display(.m4OdysseyG80SD)

    @Test func fixed120AppliesMode136WithTheCountdown() throws {
        let h = Harness(displays: [odyssey])
        h.model.select(refresh: .fixed(hertz: 120), for: h.display)
        #expect(h.service.applied == [Applied(136, odyssey.id, .session)])
        let pending = try #require(h.model.pendingConfirmation)
        #expect(pending.description == "Odyssey G80SD → 1440p at 120 Hertz")
        #expect(h.model.secondsRemaining == 15)
        #expect(h.store.allChoices.isEmpty)
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == 133)
        #expect(h.model.refreshControlState(for: h.display).label == "120 Hertz")
        #expect(h.model.tileState(.qhd1440, for: h.display).isSelected)
    }

    @Test func variableAppliesTheVariableTwin() throws {
        var fixed = odyssey
        fixed.currentModeID = 132
        let h = Harness(displays: [fixed])
        h.model.select(refresh: .variable, for: h.display)
        #expect(h.service.applied == [Applied(133, odyssey.id, .session)])
        #expect(h.model.pendingConfirmation?.description == "Odyssey G80SD → 1440p, Variable (48–240 Hertz)")
        #expect(h.model.refreshControlState(for: h.display).current == .variable(minHertz: 48, maxHertz: 240))
    }

    @Test func fixed240AppliesTheFixedTwin() {
        let h = Harness(displays: [odyssey])
        h.model.select(refresh: .fixed(hertz: 240), for: h.display)
        #expect(h.service.applied == [Applied(132, odyssey.id, .session)])
        #expect(h.model.pendingConfirmation?.description == "Odyssey G80SD → 1440p at 240 Hertz")
    }

    @Test func fixed60AppliesMode139() {
        let h = Harness(displays: [odyssey])
        h.model.select(refresh: .fixed(hertz: 60), for: h.display)
        #expect(h.service.applied == [Applied(139, odyssey.id, .session)])
    }

    @Test func theRateFollowsTheScalingVariantInEffect() {
        var oneX = odyssey
        oneX.currentModeID = 134
        let h = Harness(displays: [oneX], scaling: .hiDPI)
        h.model.select(refresh: .fixed(hertz: 120), for: h.display)
        #expect(h.service.applied == [Applied(137, odyssey.id, .session)])
        h.model.keepPending()
        #expect(h.store.choice(forDisplayID: odyssey.id)
            == DisplayChoice(preset: .qhd1440, scaling: .lowResolution, refresh: .fixed(hertz: 120)))
    }

    @Test func keepPersistsTheRefreshWithThePreset() {
        let h = Harness(displays: [odyssey])
        h.model.select(refresh: .fixed(hertz: 120), for: h.display)
        h.model.keepPending()
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.store.choice(forDisplayID: odyssey.id)
            == DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 120)))
        #expect(h.service.applied == [Applied(136, odyssey.id, .session), Applied(136, odyssey.id, .permanent)])
        #expect(h.model.statusIconStyle == .solid)
    }

    @Test func revertRestoresTheOriginalTwinAndPersistsNothing() {
        let h = Harness(displays: [odyssey])
        h.model.select(refresh: .fixed(hertz: 120), for: h.display)
        h.model.revertPending()
        #expect(h.service.applied == [Applied(136, odyssey.id, .session), Applied(133, odyssey.id, .session)])
        #expect(h.store.allChoices.isEmpty)
        #expect(h.model.displays[0].currentModeID == 133)
        #expect(h.model.refreshControlState(for: h.display).label == "Variable (48–240 Hertz)")
    }

    @Test func selectionIsIgnoredWhileAConfirmationIsPending() {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.select(refresh: .fixed(hertz: 60), for: h.display)
        #expect(h.service.applied.count == 1)
    }

    @Test func reconcileReappliesASavedFixedRateAfterAnExternalChange() {
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 120)),
                          forDisplayID: odyssey.id)
        h.model.reconcile()
        #expect(h.service.applied == [Applied(136, odyssey.id, .permanent)])
        h.now = h.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        h.model.reconcile()
        #expect(h.service.applied.count == 1)

        // Something else puts the display back on 240 Hz variable.
        _ = try? h.service.apply(modeID: 133, to: odyssey.id, persistence: .session)
        h.model.refresh()
        h.now = h.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        h.model.reconcile()
        #expect(h.service.applied.last == Applied(136, odyssey.id, .permanent))
    }

    @Test func aPresetChangeCarriesTheSavedRateOver() {
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 60)),
                          forDisplayID: odyssey.id)
        h.model.select(preset: .fullHD1080, for: h.display)
        #expect(h.service.applied == [Applied(108, odyssey.id, .session)])
        #expect(h.model.pendingConfirmation?.description == "Odyssey G80SD → 1080p (1920 × 1080) HiDPI at 60 Hertz")
        #expect(h.model.refreshFallbackNote(for: h.display) == nil)
        h.model.keepPending()
        #expect(h.store.choice(forDisplayID: odyssey.id)
            == DisplayChoice(preset: .fullHD1080, scaling: .hiDPI, refresh: .fixed(hertz: 60)))
    }

    @Test func aRateMissingFromTheNewFamilyFallsBackToHighestWithACaption() throws {
        // Strip the 30 Hz entry from 1080p HiDPI so a saved fixed 30 cannot be honoured there.
        var trimmed = odyssey
        trimmed.modes.removeAll { $0.width == 1920 && $0.height == 1080 && $0.isHiDPI && $0.roundedRefreshRate == 30 }
        let h = Harness(displays: [trimmed])
        h.store.setChoice(DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 30)),
                          forDisplayID: odyssey.id)
        h.model.select(preset: .fullHD1080, for: h.display)
        #expect(h.service.applied == [Applied(102, odyssey.id, .session)])
        #expect(h.model.refreshFallbackNote(for: h.display) == "30 Hertz isn't available at 1080p; using the highest rate")
        h.model.keepPending()
        // The caption reaches the panel through the control state once the control is enabled again.
        let state = h.model.refreshControlState(for: h.display)
        #expect(state.isEnabled && state.caption == "30 Hertz isn't available at 1080p; using the highest rate")
        let states = h.model.presets(for: h.display).map { h.model.tileState($0, for: h.display) }
        #expect(TileState.caption(hovered: nil, refreshNote: state.caption, states: states)
            == "30 Hertz isn't available at 1080p; using the highest rate")
        // The saved rate is kept for the next family that offers it.
        #expect(h.store.choice(forDisplayID: odyssey.id)?.refresh == .fixed(hertz: 30))
        // On the same display, reconcile counts the fallback as satisfied: no churn.
        h.now = h.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        h.model.reconcile()
        #expect(h.service.applied.count == 2)

        // Going back to 1440p honours it again and clears the caption.
        h.model.select(preset: .qhd1440, for: h.display)
        #expect(h.service.applied.last == Applied(141, odyssey.id, .session))
        #expect(h.model.refreshFallbackNote(for: h.display) == nil)
    }

    @Test func revertClearsTheFallbackCaption() {
        var trimmed = odyssey
        trimmed.modes.removeAll { $0.width == 1920 && $0.height == 1080 && $0.isHiDPI && $0.roundedRefreshRate == 30 }
        let h = Harness(displays: [trimmed])
        h.store.setChoice(DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 30)),
                          forDisplayID: odyssey.id)
        h.model.select(preset: .fullHD1080, for: h.display)
        #expect(h.model.refreshFallbackNote(for: h.display) != nil)
        h.model.revertPending()
        // Back on 1440p, where the saved fixed 30 is honoured: nothing to explain.
        #expect(h.model.refreshFallbackNote(for: h.display) == nil)
    }

    @Test func theFallbackCaptionIsPrunedWhenItsDisplayVanishes() throws {
        var trimmed = odyssey
        trimmed.modes.removeAll { $0.width == 1920 && $0.height == 1080 && $0.isHiDPI && $0.roundedRefreshRate == 30 }
        let macBook = try Fixtures.display(.m1MacBookAir)
        let h = Harness(displays: [trimmed, macBook])
        h.store.setChoice(DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 30)),
                          forDisplayID: odyssey.id)
        h.model.select(preset: .fullHD1080, for: h.model.displays[0])
        h.model.keepPending()
        #expect(h.model.refreshFallbackNote(for: h.model.displays[0]) != nil)
        h.service.replaceDisplays([macBook])
        h.model.refresh()
        #expect(h.model.refreshFallbackNotes.isEmpty)
    }
}

@Suite("Refresh rate on a Native display")
@MainActor
struct RefreshNativeTests {
    let odyssey = try! Fixtures.display(.m4OdysseyG80SD)

    @Test func aFixedRateOnAnUntouchedDisplayPersistsWithoutAPreset() {
        let h = Harness(displays: [odyssey])
        h.store.setOriginalModeID(132, forDisplayID: odyssey.id)
        h.model.select(refresh: .fixed(hertz: 120), for: h.display)
        #expect(h.service.applied == [Applied(136, odyssey.id, .session)])
        #expect(h.model.pendingConfirmation?.description == "Odyssey G80SD → 1440p at 120 Hertz")
        h.model.keepPending()
        // 1440p is in effect, so the rate persists with that preset.
        #expect(h.store.choice(forDisplayID: odyssey.id)
            == DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .fixed(hertz: 120)))
    }

    @Test func aFixedRateOnANonPresetResolutionPersistsAsANativeChoice() throws {
        // Put the display on a family no preset covers and the dump does not list: a synthetic
        // 1500 × 1000 HiDPI trio (fixed 240, variable 240, 120).
        var display = odyssey
        let odd = [
            DisplayModeInfo(id: 9101, width: 1500, height: 1000, pixelWidth: 3000, pixelHeight: 2000,
                            refreshRate: 240, ioFlags: 3, isUsableForDesktopGUI: true, isVariableRefresh: false),
            DisplayModeInfo(id: 9102, width: 1500, height: 1000, pixelWidth: 3000, pixelHeight: 2000,
                            refreshRate: 240, ioFlags: 3, isUsableForDesktopGUI: true, isVariableRefresh: true),
            DisplayModeInfo(id: 9103, width: 1500, height: 1000, pixelWidth: 3000, pixelHeight: 2000,
                            refreshRate: 120, ioFlags: 3, isUsableForDesktopGUI: true),
        ]
        display.modes += odd
        display.currentModeID = 9102
        let h = Harness(displays: [display])
        #expect(h.model.currentPreset(for: h.display) == nil)
        let state = h.model.refreshControlState(for: h.display)
        #expect(state.options == [.variable(minHertz: 48, maxHertz: 240), .fixed(hertz: 240), .fixed(hertz: 120)])
        #expect(state.label == "Variable (48–240 Hertz)")

        h.model.select(refresh: .fixed(hertz: 120), for: h.display)
        #expect(h.service.applied == [Applied(9103, odyssey.id, .session)])
        #expect(h.model.pendingConfirmation?.description == "Odyssey G80SD → Default Resolution at 120 Hertz")
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == 9102)
        h.model.keepPending()
        let choice = try #require(h.store.choice(forDisplayID: odyssey.id))
        #expect(choice == DisplayChoice(preset: nil, scaling: .hiDPI, refresh: .fixed(hertz: 120)))
        #expect(h.model.statusIconStyle == .outline)
        #expect(!h.model.defaultResolutionItem(for: h.display).isChecked)

        // Reconcile re-applies the rate within the original mode's family after an external change.
        _ = try? h.service.apply(modeID: 9101, to: odyssey.id, persistence: .session)
        h.model.refresh()
        h.now = h.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        h.model.reconcile()
        #expect(h.service.applied.last == Applied(9103, odyssey.id, .permanent))
        #expect(h.store.choice(forDisplayID: odyssey.id) == choice)

        // Native restores the original mode and forgets the rate.
        h.model.select(preset: nil, for: h.display)
        #expect(h.service.applied.last == Applied(9102, odyssey.id, .session))
        h.model.keepPending()
        #expect(h.store.choice(forDisplayID: odyssey.id) == nil)
        #expect(h.model.defaultResolutionItem(for: h.display).isChecked)
    }

    @Test func aNativeHighestChoiceIsStillRemovedByReconcile() {
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: nil, scaling: .hiDPI), forDisplayID: odyssey.id)
        h.model.reconcile()
        #expect(h.service.applied.isEmpty)
        #expect(h.store.choice(forDisplayID: odyssey.id) == nil)
    }

    @Test func aRateOnlyChoiceIsAnchoredOnTheCurrentFamilyNeverTheDefaultMode() {
        // No original recorded and the default-flagged mode is 103 (1080p HiDPI), yet a rate-only
        // choice never changes the resolution: 60 Hz is applied within the current 1440p family.
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: nil, scaling: .hiDPI, refresh: .fixed(hertz: 60)), forDisplayID: odyssey.id)
        h.model.reconcile()
        #expect(h.service.applied == [Applied(139, odyssey.id, .permanent)])
        #expect(h.model.currentPreset(for: h.display) == .qhd1440)
    }

    @Test func aRateChosenInAnotherFamilyThanTheOriginalStaysThere() throws {
        // Original O = 133 (1440p HiDPI) recorded; the display now sits in a family no preset
        // covers (X, synthetic 1500 × 1000 HiDPI). The rate is picked, kept and reconciled in X;
        // nothing ever pulls the display back to O's family.
        var display = odyssey
        let family = [
            DisplayModeInfo(id: 9101, width: 1500, height: 1000, pixelWidth: 3000, pixelHeight: 2000,
                            refreshRate: 240, ioFlags: 3, isUsableForDesktopGUI: true, isVariableRefresh: false),
            DisplayModeInfo(id: 9102, width: 1500, height: 1000, pixelWidth: 3000, pixelHeight: 2000,
                            refreshRate: 240, ioFlags: 3, isUsableForDesktopGUI: true, isVariableRefresh: true),
            DisplayModeInfo(id: 9103, width: 1500, height: 1000, pixelWidth: 3000, pixelHeight: 2000,
                            refreshRate: 120, ioFlags: 3, isUsableForDesktopGUI: true, isVariableRefresh: false),
        ]
        display.modes += family
        display.currentModeID = 9102
        let h = Harness(displays: [display])
        h.store.setOriginalModeID(133, forDisplayID: odyssey.id)

        h.model.select(refresh: .fixed(hertz: 120), for: h.display)
        #expect(h.service.applied == [Applied(9103, odyssey.id, .session)])
        #expect(h.model.pendingConfirmation?.description == "Odyssey G80SD → Default Resolution at 120 Hertz")
        h.model.keepPending()
        #expect(h.store.choice(forDisplayID: odyssey.id) == DisplayChoice(preset: nil, scaling: .hiDPI, refresh: .fixed(hertz: 120)))
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == 133)
        #expect(h.service.applied.last == Applied(9103, odyssey.id, .permanent))

        h.now = h.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        h.model.reconcile()
        #expect(h.service.applied.count == 2)
        #expect(h.model.displays[0].currentModeID == 9103)
        #expect(h.model.refreshFallbackNote(for: h.display) == nil)

        // The same holds when X is a preset family: the rate persists with that preset.
        var at1080 = odyssey
        at1080.currentModeID = 102
        let g = Harness(displays: [at1080])
        g.store.setOriginalModeID(133, forDisplayID: odyssey.id)
        g.model.select(refresh: .fixed(hertz: 60), for: g.display)
        #expect(g.service.applied == [Applied(108, odyssey.id, .session)])
        g.model.keepPending()
        #expect(g.store.choice(forDisplayID: odyssey.id) == DisplayChoice(preset: .fullHD1080, scaling: .hiDPI, refresh: .fixed(hertz: 60)))
        g.now = g.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        g.model.reconcile()
        #expect(g.service.applied.count == 2)
        #expect(g.model.displays[0].currentModeID == 108)
    }

    @Test func aRateOnlyChoiceFallsBackWithACaptionWhereTheFamilyLacksIt() {
        // The display was moved by other means to the 1080p 1x family, which has no 30 Hz here.
        var display = odyssey
        display.modes.removeAll { $0.width == 1920 && $0.height == 1080 && !$0.isHiDPI && $0.roundedRefreshRate == 30 }
        display.currentModeID = 104
        let h = Harness(displays: [display])
        h.store.setChoice(DisplayChoice(preset: nil, scaling: .hiDPI, refresh: .fixed(hertz: 30)), forDisplayID: odyssey.id)
        h.model.reconcile()
        // Already at the family's top rate: nothing applied, but the caption explains the rate.
        #expect(h.service.applied.isEmpty)
        #expect(h.model.refreshFallbackNote(for: h.display)
            == "30 Hertz isn't available at this resolution; using the highest rate")
        #expect(h.model.displays[0].currentMode?.pointSize == PixelSize(width: 1920, height: 1080))
    }
}

@Suite("Refresh control state and disabled states")
@MainActor
struct RefreshControlStateTests {
    let odyssey = try! Fixtures.display(.m4OdysseyG80SD)
    let macBook = try! Fixtures.display(.m1MacBookAir)

    @Test func odysseyOffersWhatItEnumerates() {
        let h = Harness(displays: [odyssey])
        let state = h.model.refreshControlState(for: h.display)
        #expect(state.options == [.variable(minHertz: 48, maxHertz: 240), .fixed(hertz: 240), .fixed(hertz: 120),
                                  .fixed(hertz: 60), .fixed(hertz: 30)])
        #expect(state.current == .variable(minHertz: 48, maxHertz: 240))
        #expect(state.label == "Variable (48–240 Hertz)")
        #expect(state.isEnabled && state.note == nil && state.caption == nil && !state.isProMotion)
        #expect(state.options.map(state.label(for:))
            == ["Variable (48–240 Hertz)", "240 Hertz", "120 Hertz", "60 Hertz", "30 Hertz"])
    }

    @Test func pendingAndBusyDisableTheControlLikeTheTiles() {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)
        let pending = h.model.refreshControlState(for: h.display)
        #expect(!pending.isEnabled && pending.note == TileState.pendingNote)
        // 1080p HiDPI's highest entry is the variable twin (102).
        #expect(pending.label == "Variable (48–240 Hertz)")
        var seen: RefreshControlState?
        h.model.presentError = { _ in seen = h.model.refreshControlState(for: h.display) }
        h.model.revertPending()
        h.service.failure = .configurationFailed(stage: .complete, code: 1000, fullScreenAppBlocking: false)
        h.model.select(refresh: .fixed(hertz: 60), for: h.display)
        #expect(seen?.isEnabled == false && seen?.note == TileState.busyNote)
    }

    /// The dump with the classifier's answers erased (SkyLight's symbols did not resolve).
    private var unclassifiedOdyssey: DisplayInfo {
        var d = odyssey
        d.modes = d.modes.map { mode in
            var mode = mode
            mode.isVariableRefresh = nil
            mode.isProMotion = nil
            return mode
        }
        return d
    }

    @Test func withoutTheClassifierOnlyRatesAreOfferedAndAnAmbiguousCurrentDisablesTheControl() {
        let h = Harness(displays: [unclassifiedOdyssey])
        let state = h.model.refreshControlState(for: h.display)
        #expect(state.options == [.fixed(hertz: 240), .fixed(hertz: 120), .fixed(hertz: 60), .fixed(hertz: 30)])
        // 133 has an unclassified twin at 240: nothing public says which one is in effect.
        #expect(state.current == nil)
        #expect(!state.isEnabled && state.note == RefreshControlState.unverifiedNote)
        #expect(state.caption == RefreshControlState.unverifiedNote)
        #expect(state.label == RefreshControlState.unknownLabel)
    }

    @Test func withoutTheClassifierAnUnambiguousCurrentKeepsTheControlAndPicksAreCaptioned() {
        var display = unclassifiedOdyssey
        display.currentModeID = 136
        let h = Harness(displays: [display])
        let state = h.model.refreshControlState(for: h.display)
        #expect(state.isEnabled && state.current == .fixed(hertz: 120) && state.caption == nil)

        h.model.select(refresh: .fixed(hertz: 240), for: h.display)
        // The 240 Hz twins cannot be told apart: the lowest id is applied and the caption says so.
        #expect(h.service.applied == [Applied(132, odyssey.id, .session)])
        #expect(h.model.refreshFallbackNote(for: h.display) == RefreshControlState.unverifiedFallbackNote)
        h.model.keepPending()
        #expect(h.store.choice(forDisplayID: odyssey.id)?.refresh == .fixed(hertz: 240))
        #expect(h.model.refreshFallbackNote(for: h.display) == RefreshControlState.unverifiedFallbackNote)
        // Reconcile treats the unverified pick as satisfied: no churn between the twins.
        h.now = h.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        h.model.reconcile()
        #expect(h.service.applied.count == 2)
    }

    @Test func aVirtualMirrorDisablesTheControlWithItsNote() {
        let h = Harness(displays: [macBook])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()
        let state = h.model.refreshControlState(for: h.model.displays[0])
        #expect(!state.isEnabled)
        #expect(state.note == "Virtual displays run at 60 Hertz")
        #expect(state.label == "60 Hertz")
        #expect(state.options.isEmpty)
        let applied = h.service.applied.count
        h.model.select(refresh: .fixed(hertz: 30), for: h.model.displays[0])
        #expect(h.service.applied.count == applied && h.model.pendingConfirmation == nil)
        h.model.cleanupForTermination()
    }

    @Test func aSingleOptionIsShownDisabledWithoutANote() {
        let h = Harness(displays: [try! Fixtures.display(.external1080p)])
        let state = h.model.refreshControlState(for: h.display)
        #expect(state.options == [.fixed(hertz: 60)])
        #expect(!state.isEnabled && state.note == nil)
        #expect(state.label == "60 Hertz")
    }

    @Test func aDisplayWithoutModesHasNothingToOffer() {
        let empty = DisplayInfo(id: "00000000-0000-0000-0000-00000000000E", name: "Ghost", isBuiltIn: false, isMain: false,
                                nativePixelSize: PixelSize(width: 0, height: 0), modes: [], currentModeID: nil)
        let h = Harness(displays: [empty])
        let state = h.model.refreshControlState(for: h.display)
        #expect(state.options.isEmpty && !state.isEnabled && state.label == RefreshControlState.unknownLabel)
    }

    @Test func proMotionLabelOnABuiltInPanel() {
        var panel = macBook
        let current = panel.modes.first { $0.id == panel.currentModeID }
        panel.modes = panel.modes.map { mode in
            var mode = mode
            if let current, mode.pointSize == current.pointSize, mode.pixelSize == current.pixelSize {
                mode.refreshRate = 120
                mode.isProMotion = true
                mode.isVariableRefresh = true
            }
            return mode
        }
        let h = Harness(displays: [panel])
        let state = h.model.refreshControlState(for: h.display)
        #expect(state.isProMotion)
        #expect(state.label == "ProMotion")
        #expect(state.options.first == .variable(minHertz: nil, maxHertz: nil))
    }
}

@Suite("Refresh labels and family selection (pure)")
struct RefreshPureTests {
    let odyssey = try! Fixtures.display(.m4OdysseyG80SD)

    @Test func optionLabels() {
        #expect(RefreshControlState.label(for: .fixed(hertz: 240), isProMotion: false) == "240 Hertz")
        #expect(RefreshControlState.label(for: .fixed(hertz: 60), isProMotion: true) == "60 Hertz")
        #expect(RefreshControlState.label(for: .variable(minHertz: 48, maxHertz: 240), isProMotion: false) == "Variable (48–240 Hertz)")
        #expect(RefreshControlState.label(for: .variable(minHertz: 47.95, maxHertz: 240), isProMotion: false) == "Variable (48–240 Hertz)")
        #expect(RefreshControlState.label(for: .variable(minHertz: nil, maxHertz: nil), isProMotion: false) == "Variable")
        #expect(RefreshControlState.label(for: .variable(minHertz: 48, maxHertz: 120), isProMotion: true) == "ProMotion")
    }

    @Test func fallbackNotes() {
        #expect(RefreshControlState.fallbackNote(refresh: .fixed(hertz: 60), preset: .uhd2160)
            == "60 Hertz isn't available at 4K; using the highest rate")
        #expect(RefreshControlState.fallbackNote(refresh: .variable, preset: nil)
            == "Variable refresh isn't available at this resolution; using the highest rate")
        #expect(RefreshControlState.fallbackNote(refresh: .highest, preset: .hd720) == nil)
    }

    @Test func stateDefaults() {
        let single = RefreshControlState(options: [.fixed(hertz: 60)], current: nil, isProMotion: false)
        #expect(!single.isEnabled && single.note == nil && single.caption == nil && single.label == "60 Hertz")
        // Several rates but no way to tell which is in effect: disabled with the unverified note.
        let unknown = RefreshControlState(options: [.fixed(hertz: 60), .fixed(hertz: 30)], current: nil, isProMotion: false)
        #expect(!unknown.isEnabled && unknown.note == RefreshControlState.unverifiedNote && unknown.label == "Refresh rate")
        let busy = RefreshControlState(options: unknown.options, current: .fixed(hertz: 30), isProMotion: false, isBusy: true)
        #expect(!busy.isEnabled && busy.note == TileState.busyNote && busy.label == "30 Hertz")
        let both = RefreshControlState(options: unknown.options, current: nil, isProMotion: false,
                                       isConfirmationPending: true, isBusy: true)
        #expect(both.note == TileState.pendingNote)
    }

    @Test func captionIsTheNoteWhenDisabledElseTheFallbackNote() {
        let enabled = RefreshControlState(options: [.fixed(hertz: 60), .fixed(hertz: 30)], current: .fixed(hertz: 60),
                                          isProMotion: false, fallbackNote: "fallback")
        #expect(enabled.isEnabled && enabled.caption == "fallback")
        let pending = RefreshControlState(options: enabled.options, current: .fixed(hertz: 60), isProMotion: false,
                                          isConfirmationPending: true, fallbackNote: "fallback")
        #expect(pending.caption == TileState.pendingNote)
        let mirrored = RefreshControlState(options: [], current: nil, isProMotion: false, isVirtualMirror: true,
                                           fallbackNote: "fallback")
        #expect(mirrored.caption == RefreshControlState.virtualNote)
    }

    @Test func captionPrefersHoverThenTheRefreshNote() {
        #expect(TileState.caption(hovered: nil, refreshNote: "note", states: []) == "note")
        #expect(TileState.caption(hovered: nil, refreshNote: nil, states: []) == "")
    }

    @Test func statusIconIgnoresTheRefreshPreference() {
        let nativeRate = DisplayChoice(preset: nil, scaling: .hiDPI, refresh: .fixed(hertz: 120))
        let presetRate = DisplayChoice(preset: .qhd1440, scaling: .hiDPI, refresh: .variable)
        #expect(StatusIconStyle.resolve(choices: [nativeRate], hasActiveMirror: false) == .outline)
        #expect(StatusIconStyle.resolve(choices: [presetRate], hasActiveMirror: false) == .solid)
    }
}
