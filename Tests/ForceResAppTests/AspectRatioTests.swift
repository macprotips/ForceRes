import Foundation
import ForceResCore
import Testing
@testable import ForceRes

@Suite("Aspect ratio choice")
@MainActor
struct AspectRatioTests {
    @Test("Each shape offers four presets and nothing overlaps")
    func laddersAreDistinct() {
        for aspect in AspectRatio.allCases {
            #expect(aspect.presets.count == 4)
            for preset in aspect.presets {
                #expect(preset.aspect == aspect)
                let ratio = Double(preset.pixelSize.width) / Double(preset.pixelSize.height)
                let expected: Double = switch aspect {
                case .sixteenByNine: 16.0 / 9
                case .sixteenByTen: 16.0 / 10
                }
                #expect(abs(ratio - expected) < 0.001, "\(preset) is not \(aspect.title)")
            }
        }
        #expect(Set(ResolutionPreset.allCases.map(\.pixelSize)).count == ResolutionPreset.allCases.count)
    }

    @Test("Stored 16:9 choices from before aspect ratios still decode")
    func oldChoicesStillDecode() throws {
        let json = #"{"preset":"fullHD1080","scaling":"hiDPI"}"#
        let choice = try JSONDecoder().decode(DisplayChoice.self, from: Data(json.utf8))
        #expect(choice.preset == .fullHD1080)
        #expect(choice.preset?.aspect == .sixteenByNine)
    }

    @Test("A display defaults to the shape it is already on, and the choice sticks")
    func defaultsToTheCurrentShapeThenRemembers() throws {
        let h = Harness(displays: [try Fixtures.display(.m1MacBookAir)])
        // The MacBook Air fixture sits at 1280x800, a 16:10 size.
        #expect(h.model.aspect(for: h.display) == .sixteenByTen)
        #expect(h.model.presets(for: h.display) == AspectRatio.sixteenByTen.presets)

        h.model.setAspect(.sixteenByNine, for: h.display)
        #expect(h.model.aspect(for: h.display) == .sixteenByNine)
        #expect(h.store.aspect(forDisplayID: h.display.id) == .sixteenByNine)
        #expect(h.model.presets(for: h.display).map(\.pixelSize.height) == [720, 1080, 1440, 2160])
        #expect(h.service.applied.isEmpty, "changing the shape must not touch the display")
    }

    @Test("Both shapes are offered on a 1080p panel: the smaller sizes of each fit")
    func bothShapesAreOffered() throws {
        let h = Harness(displays: [try Fixtures.display(.external1080p)])
        #expect(h.model.isAspectOffered(.sixteenByNine, for: h.display))
        #expect(h.model.isAspectOffered(.sixteenByTen, for: h.display))
    }
}

@Suite("Which display the panel controls")
@MainActor
struct PanelTargetTests {
    private func twoDisplays() throws -> [DisplayInfo] {
        var main = try Fixtures.display(.m4OdysseyG80SD)
        main.isMain = true
        var second = try Fixtures.display(.external1080p)
        second.id = "22222222-2222-2222-2222-222222222222"
        second.name = "Second Display"
        second.isMain = false
        return [main, second]
    }

    @Test("Opening from a screen's menu bar aims the panel at that screen")
    func opensOnTheScreenItWasClickedFrom() throws {
        let displays = try twoDisplays()
        let h = Harness(displays: displays)
        h.model.panelOpened(onDisplayID: displays[1].id)
        #expect(h.model.selectedDisplayID == displays[1].id)
    }

    @Test("Without a screen, or from one that is gone, it falls back to the main display")
    func fallsBackToMain() throws {
        let displays = try twoDisplays()
        let h = Harness(displays: displays)
        h.model.panelOpened(onDisplayID: nil)
        #expect(h.model.selectedDisplayID == displays[0].id)
        h.model.panelOpened(onDisplayID: "no-such-display")
        #expect(h.model.selectedDisplayID == displays[0].id)
    }

    @Test("Each open re-aims at the screen it was opened from")
    func reopeningReAims() throws {
        let displays = try twoDisplays()
        let h = Harness(displays: displays)
        h.model.panelOpened(onDisplayID: displays[1].id)
        h.model.selectedDisplayID = displays[0].id      // user switches with the picker
        h.model.panelOpened(onDisplayID: displays[1].id)
        #expect(h.model.selectedDisplayID == displays[1].id)
    }
}

@Suite("Finding the screen a click landed on")
struct ScreenLookupTests {
    /// Side by side, the secondary to the right of a 2560x1440 primary.
    private let sideBySide = [CGRect(x: 0, y: 0, width: 2560, height: 1440),
                              CGRect(x: 2560, y: 0, width: 1920, height: 1080)]
    /// Stacked, the secondary above the primary. AppKit's y grows upwards.
    private let stacked = [CGRect(x: 0, y: 0, width: 2560, height: 1440),
                           CGRect(x: 0, y: 1440, width: 1920, height: 1080)]
    /// Secondary to the left, so its origin is negative.
    private let toTheLeft = [CGRect(x: 0, y: 0, width: 2560, height: 1440),
                             CGRect(x: -1920, y: 0, width: 1920, height: 1080)]

    @Test func findsTheScreenUnderThePointer() {
        #expect(StatusItemController.screenIndex(containing: CGPoint(x: 100, y: 100), frames: sideBySide) == 0)
        #expect(StatusItemController.screenIndex(containing: CGPoint(x: 3000, y: 500), frames: sideBySide) == 1)
        #expect(StatusItemController.screenIndex(containing: CGPoint(x: 100, y: 2000), frames: stacked) == 1)
        #expect(StatusItemController.screenIndex(containing: CGPoint(x: -500, y: 500), frames: toTheLeft) == 1)
    }

    @Test func returnsNothingOffAnyScreen() {
        #expect(StatusItemController.screenIndex(containing: CGPoint(x: 9000, y: 9000), frames: sideBySide) == nil)
        #expect(StatusItemController.screenIndex(containing: .zero, frames: []) == nil)
    }
}
