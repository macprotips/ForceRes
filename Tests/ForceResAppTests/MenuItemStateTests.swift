import ForceResCore
import Testing
@testable import ForceRes

@Suite("Native menu entry per fixture")
@MainActor
struct MenuItemStateTests {
    @Test func odyssey() throws {
        let h = Harness(displays: [try Fixtures.display(.m4OdysseyG80SD)])
        #expect(h.model.defaultResolutionItem(for: h.display) == MenuItemState(title: "Default Resolution", isEnabled: true, isChecked: false))
    }

    @Test func macBookAir() throws {
        let h = Harness(displays: [try Fixtures.display(.m1MacBookAir)])
        #expect(h.display.isBuiltIn)
        #expect(h.model.defaultResolutionItem(for: h.display) == MenuItemState(title: "Default Resolution", isEnabled: true, isChecked: false))
    }

    @Test func external1080pIsAlreadyNative() throws {
        let h = Harness(displays: [try Fixtures.display(.external1080p)])
        #expect(h.model.defaultResolutionItem(for: h.display) == MenuItemState(title: "Default Resolution", isEnabled: true, isChecked: true))
    }

    @Test func displayWithoutModes() {
        let empty = DisplayInfo(id: "00000000-0000-0000-0000-00000000000E", name: "Ghost", isBuiltIn: false, isMain: false,
                                nativePixelSize: PixelSize(width: 0, height: 0), modes: [], currentModeID: nil)
        let h = Harness(displays: [empty])
        #expect(h.model.defaultResolutionItem(for: h.display) == MenuItemState(title: "Default Resolution · No display modes found", isEnabled: false, isChecked: false))
    }

    @Test func refreshDescriptionsUseOneUnitVocabulary() {
        #expect(ChangeDescription.refresh(240) == "240 Hertz")
        #expect(ChangeDescription.refresh(59.94) == "60 Hertz")
        #expect(ChangeDescription.refresh(0) == "adaptive refresh")
        #expect(Units.hertz(120) == "120 Hertz")
    }

    @Test func nativeIsDisabledWithTheTilesNoteWhilePendingOrBusy() throws {
        let h = Harness(displays: [try Fixtures.display(.m4OdysseyG80SD)])
        h.model.select(preset: .fullHD1080, for: h.display)
        #expect(h.model.defaultResolutionItem(for: h.display)
            == MenuItemState(title: "Default Resolution · \(TileState.pendingNote)", isEnabled: false, isChecked: false))
        // Native is ignored while the change is pending.
        h.model.select(preset: nil, for: h.display)
        #expect(h.service.applied.count == 1)
        var seen: MenuItemState?
        h.model.presentError = { _ in seen = h.model.defaultResolutionItem(for: h.display) }
        h.model.revertPending()
        #expect(h.model.defaultResolutionItem(for: h.display).isEnabled)
        h.service.failure = .configurationFailed(stage: .complete, code: 1000, fullScreenAppBlocking: false)
        h.model.select(preset: .hd720, for: h.display)
        // Reverted back onto the recorded original, so the checkmark stays while the item is busy.
        #expect(seen == MenuItemState(title: "Default Resolution · \(TileState.busyNote)", isEnabled: false, isChecked: true))
    }
}
