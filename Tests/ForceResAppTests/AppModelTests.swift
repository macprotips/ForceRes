import Foundation
import ForceResCore
import ForceResDisplay
import Testing
@testable import ForceRes

@Suite("AppModel on the Odyssey G80SD dump (native modes)")
@MainActor
struct AppModelNativeTests {
    let odyssey = try! Fixtures.display(.m4OdysseyG80SD)

    @Test func selectingAnAvailablePresetAppliesForSessionAndStartsCountdown() throws {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)

        #expect(h.service.applied == [Applied(102, odyssey.id, .session)])
        let pending = try #require(h.model.pendingConfirmation)
        #expect(pending.displayID == odyssey.id)
        #expect(pending.description == "Odyssey G80SD → 1080p (1920 × 1080) HiDPI at 240 Hertz")
        #expect(h.model.secondsRemaining == 15)
        #expect(h.store.allChoices.isEmpty)
        #expect(h.model.displays[0].currentModeID == 102)
        #expect(h.model.currentPreset(for: h.display) == .fullHD1080)
    }

    @Test func countdownTicksWithTheInjectedClock() async {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)
        await settle()
        for _ in 0..<3 {
            h.clock.advance(by: .seconds(1))
            await settle()
        }
        #expect(h.model.secondsRemaining == 12)
        #expect(h.model.pendingConfirmation != nil)
    }

    @Test func keepPersistsTheChoiceAndReappliesPermanently() {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()

        #expect(h.model.pendingConfirmation == nil)
        #expect(h.store.choice(forDisplayID: odyssey.id) == DisplayChoice(preset: .fullHD1080, scaling: .hiDPI))
        #expect(h.service.applied.map(\.persistence) == [.session, .permanent])
        #expect(h.service.applied.last?.modeID == 102)
    }

    @Test func keepFallsBackToSessionWhenPermanentFails() {
        let h = Harness(displays: [odyssey])
        h.service.failPermanentApplies = true
        h.model.select(preset: .hd720, for: h.display)
        h.model.keepPending()
        #expect(h.service.applied.map(\.persistence) == [.session, .session])
        #expect(h.store.choice(forDisplayID: odyssey.id)?.preset == .hd720)
        #expect(h.model.lastError == nil)
    }

    @Test func revertRestoresThePreviousModeAndPersistsNothing() {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.revertPending()

        #expect(h.model.pendingConfirmation == nil)
        #expect(h.service.applied == [
            Applied(102, odyssey.id, .session),
            Applied(133, odyssey.id, .session),
        ])
        #expect(h.store.allChoices.isEmpty)
        #expect(h.model.displays[0].currentModeID == 133)
    }

    @Test func timeoutReverts() async {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)
        await settle()
        for _ in 0..<15 {
            h.clock.advance(by: .seconds(1))
            await settle()
        }
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.service.applied.last == Applied(133, odyssey.id, .session))
        #expect(h.store.allChoices.isEmpty)
        #expect(h.clock.pendingSleepers == 0)
    }

    @Test func nativeOnAnUntouchedDisplayRecordsItsModeAsTheOriginalAndChangesNothing() {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: nil, for: h.display)
        // The display is in the user's own mode (133), which is by definition what Native means.
        #expect(h.service.applied.isEmpty)
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == 133)
        #expect(h.store.choice(forDisplayID: odyssey.id) == nil)
        #expect(h.model.defaultResolutionItem(for: h.display).isChecked)
    }

    @Test func nativeFallsBackToTheDefaultFlaggedModeWhenNoOriginalWasRecorded() {
        // A choice saved by an earlier build, before originals were recorded: the current mode
        // cannot be trusted as the user's own, so Native falls back to the default-flagged 103.
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: .qhd1440, scaling: .hiDPI), forDisplayID: odyssey.id)
        h.model.select(preset: nil, for: h.display)
        #expect(h.service.applied == [Applied(103, odyssey.id, .session)])
        #expect(h.model.pendingConfirmation?.description == "Odyssey G80SD → Default Resolution (1920 × 1080) HiDPI at 240 Hertz")
        #expect(h.store.originalModeID(forDisplayID: odyssey.id) == nil)
        h.model.keepPending()
        #expect(h.service.applied.last == Applied(103, odyssey.id, .permanent))
        #expect(h.store.choice(forDisplayID: odyssey.id) == nil)
        #expect(h.model.defaultResolutionItem(for: h.display).isChecked)
    }

    @Test func selectingTheCurrentModeOnlyRecordsTheChoice() {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .qhd1440, for: h.display)
        #expect(h.service.applied.isEmpty)
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.store.choice(forDisplayID: odyssey.id)?.preset == .qhd1440)
    }

    @Test func selectionIsIgnoredWhileAConfirmationIsPending() {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.select(preset: .hd720, for: h.display)
        #expect(h.service.applied.count == 1)
    }

    @Test func serviceErrorsSurfaceAsLastError() {
        let h = Harness(displays: [odyssey])
        h.service.failure = .configurationFailed(stage: .complete, code: 1000, fullScreenAppBlocking: true)
        h.model.select(preset: .fullHD1080, for: h.display)
        let error = h.model.lastError ?? ""
        #expect(error.contains("Changing Odyssey G80SD"))
        #expect(error.contains("full screen"))
        #expect(h.model.pendingConfirmation == nil)
    }

    @Test func setScalingUpdatesTheStoreWithoutTouchingDisplays() {
        let h = Harness(displays: [odyssey])
        h.model.setScaling(.lowResolution)
        #expect(h.store.scalingPreference == .lowResolution)
        #expect(h.model.scaling == .lowResolution)
        #expect(h.service.applied.isEmpty)
        #expect(h.model.tileState(.fullHD1080, for: h.display).note == nil)
    }
}

@Suite("AppModel reconcile, sleep/wake, cleanup")
@MainActor
struct AppModelReconcileTests {
    let odyssey = try! Fixtures.display(.m4OdysseyG80SD)
    let macBook = try! Fixtures.display(.m1MacBookAir)

    @Test func reconcileReappliesASavedChoiceWhenTheModeDiffers() {
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI), forDisplayID: odyssey.id)
        h.model.reconcile()
        #expect(h.service.applied == [Applied(102, odyssey.id, .permanent)])
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.model.displays[0].currentModeID == 102)
    }

    @Test func reconcileDoesNothingWhenTheModeAlreadyMatches() {
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: .qhd1440, scaling: .hiDPI), forDisplayID: odyssey.id)
        h.model.reconcile()
        #expect(h.service.applied.isEmpty)
    }

    @Test func reconcileHonoursTheSavedScalingNotTheCurrentToggle() {
        let h = Harness(displays: [odyssey], scaling: .hiDPI)
        h.store.setChoice(DisplayChoice(preset: .qhd1440, scaling: .lowResolution), forDisplayID: odyssey.id)
        h.model.reconcile()
        // The 1x family's variable twin: `.highest` prefers it the way macOS does.
        #expect(h.service.applied.map(\.modeID) == [135])
        #expect(h.model.displays[0].currentMode?.isVariableRefresh == true)
        #expect(h.model.displays[0].currentMode?.isHiDPI == false)
    }

    @Test func reconcileSkipsWhileAConfirmationIsPendingAndRespectsCooldown() {
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI), forDisplayID: odyssey.id)
        h.model.select(preset: .hd720, for: h.display)
        h.model.reconcile()
        #expect(h.service.applied.map(\.modeID) == [41])
        h.model.revertPending()
        h.model.reconcile()
        #expect(h.service.applied.map(\.modeID) == [41, 133, 102])
        // Same wall-clock instant: within the cooldown, so a mismatch is left alone.
        _ = try? h.service.apply(modeID: 133, to: odyssey.id, persistence: .session)
        h.model.refresh()
        h.model.reconcile()
        #expect(h.service.applied.map(\.modeID) == [41, 133, 102, 133])
    }

    @Test func reconfigurationEndedTriggersRefreshAndReconcile() async {
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI), forDisplayID: odyssey.id)
        h.model.start()
        #expect(h.service.applied.map(\.modeID) == [102])
        var replaced = odyssey
        replaced.currentModeID = 133
        replaced.name = "Odyssey G80SD (reconnected)"
        h.service.replaceDisplays([replaced])
        await settle()
        #expect(h.model.displays[0].name == "Odyssey G80SD (reconnected)")
        // Still inside the 5 s cooldown, so the mismatch is not re-applied yet.
        #expect(h.service.applied.map(\.modeID) == [102])
        h.model.cleanupForTermination()
    }

    @Test func reconcileRecreatesASavedVirtualChoice() {
        let h = Harness(displays: [macBook])
        h.store.setChoice(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI), forDisplayID: macBook.id)
        h.model.reconcile()
        #expect(h.provider?.created.count == 1)
        #expect(h.service.mirrors == [Mirror(macBook.id, h.provider?.created[0].id)])
        h.model.reconcile()
        #expect(h.provider?.created.count == 1)
    }

    @Test func sleepTearsDownVirtualMirrorsAndWakeReconciles() async {
        let h = Harness(displays: [macBook])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()
        let firstVirtual = h.provider?.created.first?.id
        #expect(h.model.activeVirtualMirrors[macBook.id]?.virtualID == firstVirtual)

        h.model.handleWillSleep()
        #expect(h.model.activeVirtualMirrors.isEmpty)
        #expect(h.provider?.activeDisplayIDs.isEmpty == true)
        #expect(h.service.mirrors.last == Mirror(macBook.id, nil))
        #expect(h.store.choice(forDisplayID: macBook.id)?.preset == .fullHD1080)

        h.model.handleDidWake()
        await settle()
        #expect(h.provider?.created.count == 1)
        h.clock.advance(by: .seconds(2))
        await settle()
        #expect(h.provider?.created.count == 2)
        #expect(h.model.activeVirtualMirrors[macBook.id]?.virtualID == h.provider?.created.last?.id)
        h.model.cleanupForTermination()
    }

    @Test func cleanupForTerminationRevertsAndReleasesEverythingAndIsIdempotent() {
        let h = Harness(displays: [odyssey, macBook])
        h.model.select(preset: .fullHD1080, for: h.model.displays[1])
        h.model.keepPending()
        h.model.select(preset: .hd720, for: h.model.displays[0])

        h.model.cleanupForTermination()
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.service.applied.last == Applied(133, odyssey.id, .session))
        #expect(h.model.activeVirtualMirrors.isEmpty)
        #expect(h.provider?.activeDisplayIDs.isEmpty == true)
        #expect(h.service.mirrors.last == Mirror(macBook.id, nil))

        let applied = h.service.applied.count
        let mirrors = h.service.mirrors.count
        h.model.cleanupForTermination()
        #expect(h.service.applied.count == applied)
        #expect(h.service.mirrors.count == mirrors)
        #expect(h.provider?.destroyed.count == 1)
    }

    @Test func virtualDisplaysAreHiddenFromTheDisplayList() {
        var virtual = odyssey
        virtual.id = "VIRTUAL00-0000-0000-0000-000000000001"
        virtual.name = "ForceRes 1080p"
        let h = Harness(displays: [macBook])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.service.replaceDisplays([macBook, virtual])
        h.model.refresh()
        #expect(h.model.displays.map(\.id) == [macBook.id])
        h.model.cleanupForTermination()
    }
}

@Suite("AppModel virtual mirror path (MacBook Air panel)")
@MainActor
struct AppModelVirtualTests {
    let macBook = try! Fixtures.display(.m1MacBookAir)

    @Test func selectingCreatesThenMirrorsPhysicalOntoVirtual() throws {
        let h = Harness(displays: [macBook])
        h.model.select(preset: .fullHD1080, for: h.display)

        let provider = try #require(h.provider)
        let created = try #require(provider.created.first)
        #expect(created.name == "ForceRes 1080p")
        #expect(created.pixelSize == PixelSize(width: 1920, height: 1080))
        #expect(created.hiDPI)
        #expect(created.physicalDisplayID == macBook.id)
        // Physical mirrors virtual: the physical id is the mirror, the virtual id the master.
        #expect(h.service.mirrors == [Mirror(macBook.id, created.id)])
        #expect(h.service.applied.isEmpty)
        #expect(h.model.activeVirtualMirrors[macBook.id]?.preset == .fullHD1080)
        #expect(h.model.currentPreset(for: h.display) == .fullHD1080)
        let pending = try #require(h.model.pendingConfirmation)
        #expect(pending.description == "Built-in Retina Display → 1080p (1920 × 1080) virtual, 60 Hertz, letterboxed")
    }

    @Test func revertTearsDownTheMirrorAndTheVirtualDisplay() throws {
        let h = Harness(displays: [macBook])
        h.model.select(preset: .fullHD1080, for: h.display)
        let virtualID = try #require(h.provider?.created.first?.id)
        h.model.revertPending()

        #expect(h.service.mirrors.last == Mirror(macBook.id, nil))
        #expect(h.provider?.destroyed == [virtualID])
        #expect(h.model.activeVirtualMirrors.isEmpty)
        #expect(h.store.allChoices.isEmpty)
        // The panel is back in its recorded original mode, so Native is the checked entry.
        #expect(h.store.originalModeID(forDisplayID: macBook.id) == macBook.currentModeID)
        #expect(h.model.defaultResolutionItem(for: h.display).isChecked)
    }

    @Test func keepPersistsWithoutAnyPermanentApply() {
        let h = Harness(displays: [macBook])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()
        #expect(h.store.choice(forDisplayID: macBook.id) == DisplayChoice(preset: .fullHD1080, scaling: .hiDPI))
        #expect(h.service.applied.isEmpty)
        #expect(h.model.activeVirtualMirrors[macBook.id]?.preset == .fullHD1080)
        h.model.cleanupForTermination()
    }

    @Test func nativeAfterAVirtualMirrorTearsItDownAndRevertRecreatesIt() throws {
        let h = Harness(displays: [macBook])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()
        let first = try #require(h.provider?.created.first?.id)

        h.model.select(preset: nil, for: h.display)
        #expect(h.provider?.destroyed == [first])
        #expect(h.model.activeVirtualMirrors.isEmpty)
        // Default Resolution restores the mode recorded before the first virtual mirror.
        #expect(h.service.applied.last?.modeID == macBook.currentModeID)
        #expect(ModeSelector.defaultMode(in: macBook.modes)?.id != macBook.currentModeID)

        h.model.revertPending()
        #expect(h.provider?.created.count == 2)
        #expect(h.model.activeVirtualMirrors[macBook.id]?.preset == .fullHD1080)
        h.model.cleanupForTermination()
    }

    @Test func mirrorFailureDestroysTheVirtualDisplayAndReportsTheError() throws {
        let h = Harness(displays: [macBook])
        h.service.failure = .unsafeMirrorDirection(master: "x", mirror: "y")
        h.model.select(preset: .fullHD1080, for: h.display)
        let virtualID = try #require(h.provider?.created.first?.id)
        #expect(h.provider?.destroyed == [virtualID])
        #expect(h.model.activeVirtualMirrors.isEmpty)
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.model.lastError?.contains("only change a display attached to this Mac") == true)
    }

    @Test func virtualPresetsAreIgnoredWhenUnsupported() {
        let h = Harness(displays: [macBook], virtual: false)
        #expect(!h.model.isVirtualSupported)
        h.model.select(preset: .fullHD1080, for: h.display)
        #expect(h.service.mirrors.isEmpty)
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.model.lastError == nil)
    }
}

@Suite("AppModel while a display mirrors a virtual master")
@MainActor
struct AppModelMirroredSnapshotTests {
    let macBook = try! Fixtures.display(.m1MacBookAir)

    /// The MacBook snapshot as CoreGraphics reports it while mirroring a 1080p virtual master: the
    /// list is expanded with the master's modes under new ids and the current mode is one of them
    /// (measured on the Odyssey: 272 modes and current id 267 while mirrored vs 242 normally).
    var mirroredMacBook: DisplayInfo {
        var mirrored = macBook
        let extra = [
            DisplayModeInfo(id: 9001, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160,
                            refreshRate: 60, ioFlags: 3, isUsableForDesktopGUI: true),
            DisplayModeInfo(id: 9002, width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720,
                            refreshRate: 60, ioFlags: 3, isUsableForDesktopGUI: true),
        ]
        mirrored.modes += extra
        mirrored.currentModeID = 9001
        return mirrored
    }

    private func keptVirtual1080p() -> Harness {
        let h = Harness(displays: [macBook])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()
        h.service.replaceDisplays([mirroredMacBook])
        h.model.refresh()
        return h
    }

    @Test func reconcileTrustsTheActiveMirrorOverTheExpandedModeList() {
        let h = keptVirtual1080p()
        #expect(h.model.displays[0].currentModeID == 9001)
        h.model.reconcile()
        h.model.reconcile()
        #expect(h.provider?.created.count == 1)
        #expect(h.provider?.destroyed.isEmpty == true)
        #expect(h.service.applied.isEmpty)
        #expect(h.model.activeVirtualMirrors[macBook.id]?.preset == .fullHD1080)
        h.model.cleanupForTermination()
    }

    @Test func menuUsesThePreMirrorSnapshotWhileMirrored() {
        let h = keptVirtual1080p()
        let d = h.model.displays[0]
        let full = h.model.tileState(.fullHD1080, for: d)
        #expect(full.isSelected && full.isEnabled && full.note == "Via virtual display, 60 Hertz, letterboxed")
        let hd = h.model.tileState(.hd720, for: d)
        #expect(!hd.isSelected && hd.isEnabled && hd.note == "Via virtual display, 60 Hertz, letterboxed")
        #expect(h.model.defaultResolutionItem(for: d) == MenuItemState(title: "Default Resolution", isEnabled: true, isChecked: false))
        #expect(h.model.currentPreset(for: d) == .fullHD1080)
        h.model.cleanupForTermination()
    }

    @Test func selectingWhileMirroredPicksModesFromThePreMirrorSnapshot() throws {
        let h = keptVirtual1080p()
        let d = h.model.displays[0]
        h.model.select(preset: .hd720, for: d)
        // 720p has no native mode on the real panel, so it goes virtual again, not to mode 9002.
        #expect(h.service.applied.isEmpty)
        #expect(h.provider?.created.count == 2)
        #expect(h.provider?.created.last?.pixelSize == PixelSize(width: 1280, height: 720))
        h.model.revertPending()
        #expect(h.model.activeVirtualMirrors[macBook.id]?.preset == .fullHD1080)
        #expect(h.provider?.created.count == 3)

        h.service.replaceDisplays([mirroredMacBook])
        h.model.refresh()
        h.model.select(preset: nil, for: h.model.displays[0])
        let originalID = try #require(macBook.currentModeID)
        #expect(h.service.applied.map(\.modeID) == [originalID])
        #expect(h.model.activeVirtualMirrors.isEmpty)
        h.model.cleanupForTermination()
    }

    @Test func reconcileReleasesAMirrorWhoseSavedChoiceChangedWithoutApplyingAMode() {
        let h = keptVirtual1080p()
        h.store.setChoice(DisplayChoice(preset: nil, scaling: .hiDPI), forDisplayID: macBook.id)
        h.model.reconcile()
        #expect(h.model.activeVirtualMirrors.isEmpty)
        #expect(h.service.mirrors.last == Mirror(macBook.id, nil))
        #expect(h.provider?.activeDisplayIDs.isEmpty == true)
        // Nothing is applied from the still-expanded list; macOS restores the panel by itself.
        #expect(h.service.applied.isEmpty)
        // Native choices are no longer persisted; the stale one is dropped.
        #expect(h.store.choice(forDisplayID: macBook.id) == nil)
        h.model.cleanupForTermination()
    }

    @Test func virtualRevertDoesNotApplyAModeWhileThePanelLeavesTheMirrorSet() throws {
        let h = Harness(displays: [macBook])
        h.model.select(preset: .fullHD1080, for: h.display)
        let virtualID = try #require(h.provider?.created.first?.id)
        h.model.revertPending()
        #expect(h.service.applied.isEmpty)
        #expect(h.service.mirrors.last == Mirror(macBook.id, nil))
        #expect(h.provider?.destroyed == [virtualID])
        #expect(h.store.allChoices.isEmpty)
    }

    @Test func aDeadHelperDropsTrackingAndUnmirrorsThePhysicalDisplay() throws {
        let h = keptVirtual1080p()
        let provider = try #require(h.provider)
        let virtualID = try #require(provider.created.first?.id)
        provider.simulateHelperExit(displayID: virtualID)
        h.model.refresh()
        #expect(h.model.activeVirtualMirrors.isEmpty)
        #expect(h.service.mirrors.last == Mirror(macBook.id, nil))
        #expect(provider.destroyed.isEmpty)
        #expect(h.store.choice(forDisplayID: macBook.id)?.preset == .fullHD1080)
        // Reconciliation is held back while the panel's mode list is still the expanded one.
        h.model.reconcile()
        #expect(provider.created.count == 1)
        // Once macOS has restored the panel and the cooldown has elapsed, the saved choice is
        // recreated as a fresh virtual mirror.
        h.service.replaceDisplays([macBook])
        h.model.refresh()
        h.now = h.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        h.model.reconcile()
        #expect(provider.created.count == 2)
        h.model.cleanupForTermination()
    }

    @Test func aDestroyedVirtualDisplayStillListedByCoreGraphicsIsHidden() throws {
        let h = Harness(displays: [macBook])
        h.model.select(preset: .fullHD1080, for: h.display)
        let virtualID = try #require(h.provider?.created.first?.id)
        h.model.revertPending()
        var ghost = macBook
        ghost.id = virtualID
        ghost.name = "ForceRes 1080p"
        ghost.modes = []
        ghost.currentModeID = nil
        h.service.replaceDisplays([macBook, ghost])
        h.model.refresh()
        #expect(h.model.displays.map(\.id) == [macBook.id])
        h.service.replaceDisplays([macBook])
        h.model.refresh()
        #expect(h.model.displays.map(\.id) == [macBook.id])
    }

    @Test("termination and sleep never recreate a mirror a pending change replaced",
          arguments: [true, false])
    func finalRevertsSpawnNoHelper(terminating: Bool) throws {
        // A kept 1080p mirror, then Native pending on top of it: the revert would normally bring
        // the mirror back, which on the way out would spawn a helper only to destroy it.
        let h = Harness(displays: [macBook])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()
        let first = try #require(h.provider?.created.first?.id)
        h.model.select(preset: nil, for: h.model.displays[0])
        #expect(h.model.pendingConfirmation != nil)
        #expect(h.provider?.destroyed == [first])

        if terminating { h.model.cleanupForTermination() } else { h.model.handleWillSleep() }
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.provider?.created.count == 1)
        #expect(h.provider?.activeDisplayIDs.isEmpty == true)
        #expect(h.model.activeVirtualMirrors.isEmpty)
        // The saved choice survives, so the next launch or wake recreates the mirror.
        #expect(h.store.choice(forDisplayID: macBook.id)?.preset == .fullHD1080)
        h.model.cleanupForTermination()
    }

    @Test("a pending mirror replacing a kept mirror is torn down without recreating the old one",
          arguments: [true, false])
    func finalRevertOfAVirtualChangeSpawnsNoHelper(terminating: Bool) {
        let h = Harness(displays: [macBook])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()
        h.model.select(preset: .hd720, for: h.model.displays[0])
        #expect(h.provider?.created.count == 2)

        if terminating { h.model.cleanupForTermination() } else { h.model.handleWillSleep() }
        #expect(h.provider?.created.count == 2)
        #expect(h.provider?.activeDisplayIDs.isEmpty == true)
        #expect(h.model.activeVirtualMirrors.isEmpty)
        h.model.cleanupForTermination()
    }

    @Test func cleanupForTerminationStopsReactingToReconfigurations() async {
        let h = Harness(displays: [macBook])
        h.store.setChoice(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI), forDisplayID: macBook.id)
        h.model.start()
        #expect(h.provider?.created.count == 1)
        h.model.cleanupForTermination()
        #expect(h.model.activeVirtualMirrors.isEmpty)
        h.service.replaceDisplays([macBook])
        await settle()
        #expect(h.provider?.created.count == 1)
        #expect(h.provider?.activeDisplayIDs.isEmpty == true)
        h.model.cleanupForTermination()
        #expect(h.provider?.created.count == 1)
    }
}

@Suite("AppModel errors, unplug, sleep, cooldown follow-up, re-entrancy, icon")
@MainActor
struct AppModelRobustnessTests {
    let odyssey = try! Fixtures.display(.m4OdysseyG80SD)
    let macBook = try! Fixtures.display(.m1MacBookAir)

    @Test func reconcileErrorStartsTheCooldownSoItIsNotRetriedEveryEvent() {
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI), forDisplayID: odyssey.id)
        h.service.failure = .configurationFailed(stage: .complete, code: 1000, fullScreenAppBlocking: false)
        var reports: [String] = []
        h.model.presentError = { reports.append($0) }
        h.model.reconcile()
        #expect(reports.count == 1)
        h.model.reconcile()
        #expect(reports.count == 1)
        h.now = h.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        h.model.reconcile()
        #expect(reports.count == 2)
    }

    @Test func unpluggingTheDisplayDuringACountdownEndsItWithoutRevert() async {
        let h = Harness(displays: [odyssey, macBook])
        h.model.select(preset: .fullHD1080, for: h.model.displays[0])
        #expect(h.model.pendingConfirmation != nil)
        h.service.replaceDisplays([macBook])
        h.model.refresh()
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.model.secondsRemaining == 0)
        #expect(h.service.applied == [Applied(102, odyssey.id, .session)])
        #expect(h.store.allChoices.isEmpty)
        await settle()
        #expect(h.clock.pendingSleepers == 0)
    }

    @Test func sleepDuringACountdownRevertsBeforeReleasingMirrors() {
        let h = Harness(displays: [odyssey, macBook])
        h.model.select(preset: .fullHD1080, for: h.model.displays[1])
        h.model.keepPending()
        h.model.select(preset: .hd720, for: h.model.displays[0])
        #expect(h.model.pendingConfirmation != nil)

        h.model.handleWillSleep()
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.service.applied.map(\.modeID) == [41, 133])
        #expect(h.model.activeVirtualMirrors.isEmpty)
        #expect(h.provider?.activeDisplayIDs.isEmpty == true)
        #expect(h.store.choice(forDisplayID: odyssey.id) == nil)
        #expect(h.store.choice(forDisplayID: macBook.id)?.preset == .fullHD1080)
    }

    @Test func keepReconcilesOtherDisplaysHeldBackWhilePending() {
        let h = Harness(displays: [odyssey, macBook])
        h.store.setChoice(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI), forDisplayID: macBook.id)
        h.model.select(preset: .hd720, for: h.model.displays[0])
        #expect(h.provider?.created.isEmpty == true)
        h.model.keepPending()
        #expect(h.provider?.created.count == 1)
        #expect(h.store.choice(forDisplayID: odyssey.id)?.preset == .hd720)
        h.model.cleanupForTermination()
    }

    @Test func aCooldownSkipSchedulesOneFollowUpReconcile() async {
        let h = Harness(displays: [odyssey])
        h.store.setChoice(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI), forDisplayID: odyssey.id)
        h.model.reconcile()
        #expect(h.service.applied.map(\.modeID) == [102])
        // An external change inside the cooldown is skipped, and a follow-up is scheduled.
        _ = try? h.service.apply(modeID: 132, to: odyssey.id, persistence: .session)
        h.model.refresh()
        h.model.reconcile()
        h.model.reconcile()
        await settle()
        #expect(h.service.applied.map(\.modeID) == [102, 132])
        #expect(h.clock.pendingSleepers == 1)

        h.clock.advance(by: .seconds(AppModel.reconcileCooldown - 1))
        await settle()
        #expect(h.service.applied.map(\.modeID) == [102, 132])
        h.now = h.now.addingTimeInterval(AppModel.reconcileCooldown + 1)
        h.clock.advance(by: .seconds(1))
        await settle()
        #expect(h.service.applied.map(\.modeID) == [102, 132, 102])
        #expect(h.clock.pendingSleepers == 0)
        h.model.cleanupForTermination()
    }

    @Test func reconcileIsSkippedWhileAChangeIsBeingApplied() {
        let h = Harness(displays: [odyssey, macBook])
        h.store.setChoice(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI), forDisplayID: macBook.id)
        var busyDuringError = false
        var reconciledDuringError = false
        h.model.presentError = { _ in
            busyDuringError = h.model.isBusy
            h.model.reconcile()
            reconciledDuringError = h.provider?.created.isEmpty == false
        }
        h.service.failure = .configurationFailed(stage: .complete, code: 1000, fullScreenAppBlocking: false)
        h.model.select(preset: .hd720, for: h.model.displays[0])
        #expect(busyDuringError)
        #expect(!reconciledDuringError)
        #expect(!h.model.isBusy)
        h.service.failure = nil
        h.model.reconcile()
        #expect(h.provider?.created.count == 1)
        h.model.cleanupForTermination()
    }

    @Test func nonPhysicalDisplaysAreExcluded() {
        var thirdParty = odyssey
        thirdParty.id = "THIRDPARTY-0000-0000-0000-000000000001"
        thirdParty.name = "Someone else's virtual display"
        thirdParty.isPhysical = false
        let h = Harness(displays: [thirdParty, macBook])
        #expect(h.model.displays.map(\.id) == [macBook.id])
        h.store.setChoice(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI), forDisplayID: thirdParty.id)
        h.model.reconcile()
        #expect(h.service.applied.isEmpty)
        #expect(h.service.mirrors.isEmpty)
    }

    @Test func refreshKeepsTheDisplaysValueWhenNothingChanged() {
        let h = Harness(displays: [odyssey])
        let before = h.model.displays
        h.model.refresh()
        #expect(h.model.displays == before)
        var renamed = odyssey
        renamed.name = "Renamed"
        h.service.replaceDisplays([renamed])
        h.model.refresh()
        #expect(h.model.displays[0].name == "Renamed")
    }

    @Test func statusIconFollowsSavedChoicesAndMirrors() {
        let h = Harness(displays: [odyssey, macBook])
        #expect(h.model.statusIconStyle == .outline)
        h.model.select(preset: .fullHD1080, for: h.model.displays[0])
        #expect(h.model.statusIconStyle == .outline)
        h.model.keepPending()
        #expect(h.model.statusIconStyle == .solid)
        h.model.select(preset: nil, for: h.model.displays[0])
        h.model.keepPending()
        #expect(h.model.statusIconStyle == .outline)

        h.model.select(preset: .fullHD1080, for: h.model.displays[1])
        #expect(h.model.statusIconStyle == .solid)
        h.model.revertPending()
        #expect(h.model.statusIconStyle == .outline)

        // A saved choice for a display that is not connected does not count.
        h.store.setChoice(DisplayChoice(preset: .hd720, scaling: .hiDPI), forDisplayID: "not-connected")
        let fresh = AppModel(service: h.service, store: h.store, virtualProvider: h.provider,
                             clock: h.clock, launchAtLoginAvailable: false)
        fresh.refresh()
        #expect(fresh.statusIconStyle == .outline)
    }
}
