import AppKit
import CoreGraphics
import Foundation
import ForceResCore
import Testing
@testable import ForceResDisplay

private let liveEnabled = ProcessInfo.processInfo.environment["FORCERES_LIVE_TESTS"] == "1"

/// The main display's CoreGraphics id and UUID, or nil when the service reports none.
private func mainDisplay() throws -> (cgID: CGDirectDisplayID, info: DisplayInfo)? {
    guard let info = try CoreGraphicsDisplayService().snapshot().first(where: \.isMain) else { return nil }
    return (try CoreGraphicsDisplayService.directDisplayID(for: info.id), info)
}

@Suite("VariableRefreshClassifier", .serialized)
struct VariableRefreshClassifierTests {
    /// The SkyLight symbols are private and may vanish in a macOS release; the app degrades to
    /// unclassified modes then (`RefreshOutcome.unverified`), so their absence is a skip with a
    /// reason, not a failure. The gated Odyssey test below still proves the answers when present.
    @Test(.enabled(if: VariableRefreshClassifier.isAvailable,
                   "SkyLight SLSIsDisplayModeVRR did not resolve on this macOS; the classifier is unavailable"))
    func privateClassifierResolvesOnThisMachine() {
        #expect(VariableRefreshClassifier.isAvailable)
        #expect(VariableRefreshClassifier.missingSymbols.isEmpty,
                "missing symbols: \(VariableRefreshClassifier.missingSymbols.joined(separator: ", "))")
    }

    @Test func snapshotClassifiesEveryModeWhenAvailable() throws {
        for display in try CoreGraphicsDisplayService().snapshot() {
            for mode in display.modes {
                #expect((mode.isVariableRefresh == nil) == !VariableRefreshClassifier.isAvailable, "mode \(mode.id)")
            }
        }
    }

    @Test("Odyssey twins: 133/102 variable, 132/103 fixed (docs/RESEARCH.md section 11)",
          .enabled(if: liveEnabled, "set FORCERES_LIVE_TESTS=1 to run against the Odyssey"))
    func odysseyTwinsAreClassified() throws {
        let (cgID, display) = try #require(try mainDisplay())
        try #require(display.name.contains("Odyssey"), "this check is specific to the Odyssey G80SD")
        for (id, expected): (Int32, Bool) in [(133, true), (132, false), (102, true), (103, false)] {
            #expect(VariableRefreshClassifier.isVariableRefresh(displayID: cgID, modeID: id) == expected, "\(id)")
            #expect(display.modes.first { $0.id == id }?.isVariableRefresh == expected, "\(id)")
            #expect(VariableRefreshClassifier.isProMotion(displayID: cgID, modeID: id) == false, "\(id)")
        }
    }
}

@Suite("Variable refresh range from IOKit")
struct VariableRefreshRangeTests {
    @Test func fixedPointAttributesConvertToHertz() {
        let attributes: [String: Any] = ["SupportsVariableRefreshRate": true,
                                         "MinimumVariableRefreshRate": 3_145_728,
                                         "MaximumVariableRefreshRate": 15_728_640]
        #expect(PhysicalDisplayDetector.variableRefreshRange(from: attributes) == 48...240)
        var unsupported = attributes
        unsupported["SupportsVariableRefreshRate"] = false
        #expect(PhysicalDisplayDetector.variableRefreshRange(from: unsupported) == nil)
        var zero = attributes
        zero["MinimumVariableRefreshRate"] = 0
        #expect(PhysicalDisplayDetector.variableRefreshRange(from: zero) == nil)
        var inverted = attributes
        inverted["MaximumVariableRefreshRate"] = 65_536
        #expect(PhysicalDisplayDetector.variableRefreshRange(from: inverted) == nil)
        #expect(PhysicalDisplayDetector.variableRefreshRange(from: [:]) == nil)
    }

    @Test func detectorLooksRangesUpByIdentity() {
        let odyssey = PhysicalDisplayDetector.Identity(vendor: 19501, product: 57397)
        let detector = PhysicalDisplayDetector(identities: [odyssey], variableRefreshRanges: [odyssey: 48...240])
        #expect(detector.variableRefreshRange(vendor: 19501, model: 57397) == 48...240)
        #expect(detector.variableRefreshRange(vendor: 19501, model: 1) == nil)
        #expect(PhysicalDisplayDetector(identities: [odyssey]).variableRefreshRange(vendor: 19501, model: 57397) == nil)
    }

    @Test("The Odyssey advertises 48-240 Hz", .enabled(if: liveEnabled, "set FORCERES_LIVE_TESTS=1"))
    func odysseyAdvertisesItsRange() throws {
        let (_, display) = try #require(try mainDisplay())
        try #require(display.name.contains("Odyssey"), "this check is specific to the Odyssey G80SD")
        #expect(display.variableRefreshRange == 48...240)
    }
}

@Suite("RefreshRateProbe", .serialized)
@MainActor
struct RefreshRateProbeTests {
    @Test func reportsEveryOnlineScreen() throws {
        for cgID in CoreGraphicsDisplayService.onlineDisplayIDs() where CGDisplayMirrorsDisplay(cgID) == kCGNullDirectDisplay {
            let state = try #require(RefreshRateProbe.activeRefresh(for: cgID))
            #expect(state.maxFPS > 0)
        }
        #expect(RefreshRateProbe.activeRefresh(for: 0xFFFF_FFF0) == nil)
    }

    @Test("The main display runs variable refresh at its current mode",
          .enabled(if: liveEnabled, "set FORCERES_LIVE_TESTS=1"))
    func mainDisplayIsVariableAtRest() throws {
        let (cgID, display) = try #require(try mainDisplay())
        let state = try #require(RefreshRateProbe.activeRefresh(for: cgID))
        #expect(display.currentMode?.isVariableRefresh == true)
        #expect(state.isVariable)
        #expect(state.maxFPS == display.currentMode?.roundedRefreshRate)
    }
}

extension VirtualDisplayControllerLiveHelperTests {
    /// Lives in the serialized live-helper suite on purpose: swift-testing runs different suites
    /// concurrently, and WindowServer records the single-display configuration (including the
    /// held 120 Hz fixed mode) into `com.apple.windowserver.displays` whenever another test adds a
    /// virtual display meanwhile. Session-scoped applies alone never touch that file (measured).
    @Test("Applying 1440p HiDPI @ 120 fixed (136) reads back 120 fixed, and 133 restores variable",
          .enabled(if: liveEnabled, "set FORCERES_LIVE_TESTS=1: this switches the real display"))
    @MainActor
    func fixed120ReadsBackThenRevertsToVariable() throws {
        let service = CoreGraphicsDisplayService()
        let (cgID, display) = try #require(try mainDisplay())
        let original = try #require(display.currentModeID)
        try #require(display.currentMode?.isVariableRefresh == true, "start from the variable mode")
        let fixed120 = try #require(display.modes.first {
            $0.pointSize == display.currentMode?.pointSize && $0.pixelSize == display.currentMode?.pixelSize
                && $0.roundedRefreshRate == 120 && $0.isVariableRefresh == false && $0.isUsableForDesktopGUI
        })
        try service.apply(modeID: fixed120.id, to: display.id, persistence: .session)
        defer {
            // Always restore, even when an expectation above fails.
            _ = try? service.apply(modeID: original, to: display.id, persistence: .session)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
        let held = try #require(RefreshRateProbe.activeRefresh(for: cgID))
        #expect(held.maxFPS == 120)
        #expect(!held.isVariable)
        #expect(try service.currentModeID(for: display.id) == fixed120.id)

        try service.apply(modeID: original, to: display.id, persistence: .session)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
        let restored = try #require(RefreshRateProbe.activeRefresh(for: cgID))
        #expect(restored.isVariable)
        #expect(restored.maxFPS == display.currentMode?.roundedRefreshRate)
        #expect(try service.currentModeID(for: display.id) == original)
    }
}
