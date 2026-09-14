import Foundation
import ForceResCore
import ForceResDisplay
import Testing
@testable import ForceRes

/// The recorded original mode: what "Native" restores and what breaks ties between duplicate
/// mode entries. The Odyssey G80SD dump records the current mode as id 133, the byte-identical
/// variable twin of 132 (docs/RESEARCH.md addendum): the default-flagged mode there is 103
/// (1080p HiDPI), not the user's 1440p.
@Suite("AppModel original mode recording and restore")
@MainActor
struct OriginalModeTests {
    let odyssey = try! Fixtures.display(.m4OdysseyG80SD)
    let macBook = try! Fixtures.display(.m1MacBookAir)

    @Test func fixtureHasTheDuplicatePairAndADifferentDefault() throws {
        // 132 and 133 are byte-identical to CoreGraphics; the fixture's classifier marks 133 as
        // the variable-refresh twin (docs/RESEARCH.md section 11).
        let twin132 = try #require(odyssey.modes.first { $0.id == 132 })
        var twin133 = try #require(odyssey.modes.first { $0.id == 133 })
        #expect(twin132.isVariableRefresh == false && twin133.isVariableRefresh == true)
        twin133.id = 132
        twin133.isVariableRefresh = twin132.isVariableRefresh
        #expect(twin132 == twin133)
        #expect(ModeSelector.defaultMode(in: odyssey.modes)?.id == 103)
        // Highest prefers the variable twin the way macOS does; a fixed 240 asks for the other one.
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: odyssey.modes)?.id == 133)
        #expect(ModeSelector.selectMode(for: .qhd1440, scaling: .hiDPI, in: odyssey.modes,
                                        refresh: .fixed(hertz: 240))?.id == 132)
    }

    @Test func originalIsRecordedOnTheFirstSelectAndNeverOverwritten() {
        let h = Harness(displays: [odyssey])
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == nil)
        h.model.select(preset: .fullHD1080, for: h.display)
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == 133)
        #expect(h.service.applied == [Applied(102, odyssey.id, .session)])
        h.model.keepPending()
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == 133)

        h.model.select(preset: .hd720, for: h.display)
        h.model.keepPending()
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == 133)
        #expect(h.store.choice(forDisplayID: odyssey.id)?.preset == .hd720)
    }

    @Test func originalIsNotRecordedWhenASavedChoiceExplainsTheCurrentMode() {
        var forced = odyssey
        forced.currentModeID = 102
        let h = Harness(displays: [forced])
        h.store.setChoice(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI), forDisplayID: odyssey.id)
        h.model.select(preset: .hd720, for: h.display)
        #expect(h.service.applied.map(\.modeID) == [41])
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == nil)
    }

    @Test func nativeRestoresTheRecordedOriginalEvenThoughTheDefaultFlaggedModeDiffers() throws {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()
        #expect(h.model.displays[0].currentModeID == 102)
        #expect(!h.model.defaultResolutionItem(for: h.display).isChecked)

        h.model.select(preset: nil, for: h.display)
        #expect(h.service.applied.last == Applied(133, odyssey.id, .session))
        let pending = try #require(h.model.pendingConfirmation)
        #expect(pending.description == "Odyssey G80SD → Default Resolution (2560 × 1440) HiDPI at 240 Hertz")
        #expect(h.model.defaultResolutionItem(for: h.display).isChecked)

        h.model.keepPending()
        #expect(h.service.applied.last == Applied(133, odyssey.id, .permanent))
        #expect(h.store.choice(forDisplayID: odyssey.id) == nil)
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == 133)
        #expect(h.model.defaultResolutionItem(for: h.display) == MenuItemState(title: "Default Resolution", isEnabled: true, isChecked: true))
        #expect(h.model.currentPreset(for: h.display) == .qhd1440)
    }

    @Test func revertingANativeChangeKeepsThePresetChoiceAndTheOriginal() {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()
        h.model.select(preset: nil, for: h.display)
        h.model.revertPending()
        #expect(h.service.applied.last == Applied(102, odyssey.id, .session))
        #expect(h.store.choice(forDisplayID: odyssey.id)?.preset == .fullHD1080)
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == 133)
        #expect(!h.model.defaultResolutionItem(for: h.display).isChecked)
    }

    @Test func afterANativeKeepReconcileLeavesTheDisplayAlone() {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()
        h.model.select(preset: nil, for: h.display)
        h.model.keepPending()
        let applied = h.service.applied.count

        // The user changes the mode by other means; with no saved choice, nothing is re-applied.
        _ = try? h.service.apply(modeID: 41, to: odyssey.id, persistence: .session)
        h.model.refresh()
        h.now = h.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        h.model.reconcile()
        #expect(h.service.applied.count == applied + 1)
        #expect(h.model.displays[0].currentModeID == 41)
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == 133)
    }

    @Test func aLegacyPersistedNativeChoiceIsRemovedByReconcileWithoutApplyingAnything() {
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: nil, scaling: .hiDPI), forDisplayID: odyssey.id)
        h.model.reconcile()
        #expect(h.service.applied.isEmpty)
        #expect(h.store.choice(forDisplayID: odyssey.id) == nil)
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == nil)
    }

    @Test func preferredTieBreakPicksTheRecordedIDOverItsLowerNumberedTwin() {
        let h = Harness(displays: [odyssey])
        // Selecting the preset the display is already in stays a no-op (133 is preferred over 132).
        h.model.select(preset: .qhd1440, for: h.display)
        #expect(h.service.applied.isEmpty)
        #expect(h.store.choice(forDisplayID: odyssey.id)?.preset == .qhd1440)
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == 133)
        h.store.removeChoice(forDisplayID: odyssey.id)

        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()
        guard case .available(let mode, _) = h.model.availability(of: .qhd1440, for: h.display) else {
            Issue.record("1440p should be available")
            return
        }
        #expect(mode.id == 133)
        h.model.select(preset: .qhd1440, for: h.display)
        #expect(h.service.applied.last == Applied(133, odyssey.id, .session))
        h.model.keepPending()

        // Reconcile uses the same tie-break: nothing to re-apply while the display sits on 133.
        h.now = h.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        let applied = h.service.applied.count
        h.model.reconcile()
        #expect(h.service.applied.count == applied)
    }

    @Test func withoutARecordedOriginalTheCurrentModeStillWinsTheTie() {
        let h = Harness(displays: [odyssey])
        guard case .available(let mode, _) = h.model.availability(of: .qhd1440, for: h.display) else {
            Issue.record("1440p should be available")
            return
        }
        #expect(mode.id == 133)
        #expect(h.model.currentPreset(for: h.display) == .qhd1440)
    }

    @Test func nativeCheckmarkFollowsTheRestoreMode() {
        let h = Harness(displays: [odyssey])
        // No original recorded: Native means the default-flagged 103, which is not current.
        #expect(h.model.defaultResolutionItem(for: h.display) == MenuItemState(title: "Default Resolution", isEnabled: true, isChecked: false))
        h.store.setOriginalModeID(133, forDisplayID: odyssey.id)
        #expect(h.model.defaultResolutionItem(for: h.display).isChecked)
        h.store.setOriginalModeID(132, forDisplayID: odyssey.id)
        #expect(!h.model.defaultResolutionItem(for: h.display).isChecked)
        // An original that is no longer listed falls back to the default mode.
        h.store.setOriginalModeID(9999, forDisplayID: odyssey.id)
        #expect(!h.model.defaultResolutionItem(for: h.display).isChecked)
        _ = try? h.service.apply(modeID: 103, to: odyssey.id, persistence: .session)
        h.model.refresh()
        #expect(h.model.defaultResolutionItem(for: h.display).isChecked)
    }

    @Test func theVirtualMirrorPathRecordsTheOriginalBeforeMirroringAndNativeRestoresIt() throws {
        let h = Harness(displays: [macBook])
        let originalID = try #require(macBook.currentModeID)
        h.model.select(preset: .fullHD1080, for: h.display)
        #expect(h.store.originalModeID(forDisplayID: macBook.id) == originalID)
        #expect(!h.model.defaultResolutionItem(for: h.display).isChecked)
        h.model.keepPending()

        h.model.select(preset: nil, for: h.display)
        #expect(h.model.activeVirtualMirrors.isEmpty)
        #expect(h.service.applied == [Applied(originalID, macBook.id, .session)])
        h.model.keepPending()
        #expect(h.store.choice(forDisplayID: macBook.id) == nil)
        #expect(h.store.originalModeID(forDisplayID: macBook.id) == originalID)
        #expect(h.model.defaultResolutionItem(for: h.display).isChecked)
        h.model.cleanupForTermination()
    }
}
