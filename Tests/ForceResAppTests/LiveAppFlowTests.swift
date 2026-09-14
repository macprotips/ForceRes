import CoreGraphics
import Foundation
import ForceResCore
import ForceResDisplay
import Testing
@testable import ForceRes

/// Gates and shared plumbing for the live suite. Nothing here touches a display until a test runs.
enum LiveEnvironment {
    /// `FORCERES_LIVE_TESTS=1 swift test --filter LiveAppFlowTests` opts in; these tests switch the
    /// real main display and create a real virtual display, so they never run by default.
    static let isEnabled = ProcessInfo.processInfo.environment["FORCERES_LIVE_TESTS"] == "1"

    /// `.build/debug/forceres-vdhost`, resolved from this file's location in the repository.
    static let helperURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // ForceResAppTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // repository root
        .appendingPathComponent(".build/debug/\(VirtualDisplayHostProtocol.executableName)")

    static var helperExists: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }

    /// `.build/debug/forceres-probe`, used to count online displays from a *fresh* process: this
    /// process's own `CGGetOnlineDisplayList` can keep listing a retired virtual display for ~30 s
    /// after it was a mirror master (docs/RESEARCH.md addendum).
    static let probeURL = helperURL.deletingLastPathComponent().appendingPathComponent("forceres-probe")

    /// Number of displays a fresh process sees, or nil if the probe is unavailable.
    static func externalOnlineDisplayCount() -> Int? {
        guard FileManager.default.isExecutableFile(atPath: probeURL.path) else { return nil }
        let process = Process()
        process.executableURL = probeURL
        process.arguments = ["--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let displays = object["displays"] as? [Any] else { return nil }
        return displays.count
    }
}

/// Drives the real `AppModel` against CoreGraphics on the main display, restoring it afterwards.
///
/// Each test records the main display's current mode id first and applies it again (session scope)
/// in a `defer` so the display always ends where it started, whatever the assertions say.
@Suite("Live app flows on the main display", .serialized,
       .enabled(if: LiveEnvironment.isEnabled, "set FORCERES_LIVE_TESTS=1 to run the live suite"))
@MainActor
struct LiveAppFlowTests {
    /// A live model with its real collaborators; `stop()` is the termination cleanup.
    @MainActor
    struct Live {
        let registry = VirtualDisplayRegistry()
        let service: CoreGraphicsDisplayService
        let controller: VirtualDisplayController
        let store = InMemoryPreferencesStore()
        let model: AppModel
        let displayID: String
        let originalModeID: Int32

        init() throws {
            // Let the previous test's display changes settle before recording the baseline.
            let mainID = CGMainDisplayID()
            let deadline = Date().addingTimeInterval(15)
            var stableSince = Date()
            var lastMode = CGDisplayCopyDisplayMode(mainID)?.ioDisplayModeID
            while Date() < deadline {
                let mode = CGDisplayCopyDisplayMode(mainID)?.ioDisplayModeID
                if mode != lastMode { lastMode = mode; stableSince = Date() }
                if CGDisplayMirrorsDisplay(mainID) == kCGNullDirectDisplay, Date().timeIntervalSince(stableSince) >= 1 { break }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            }
            service = CoreGraphicsDisplayService(virtualDisplays: registry)
            controller = VirtualDisplayController(service: service, registry: registry,
                                                  helperURL: LiveEnvironment.helperURL)
            model = AppModel(service: service, store: store, virtualProvider: controller,
                             clock: ContinuousClock(), now: { Date() }, launchAtLoginAvailable: false)
            displayID = try #require(CoreGraphicsDisplayService.uuidString(for: CGMainDisplayID()))
            originalModeID = try #require(try service.currentModeID(for: displayID))
            model.start()
        }

        var display: DisplayInfo {
            get throws { try #require(model.displays.first { $0.id == displayID }) }
        }

        func currentModeID() throws -> Int32? { try service.currentModeID(for: displayID) }

        func currentPointSize() throws -> PixelSize? {
            guard let id = try currentModeID() else { return nil }
            return try service.modes(for: displayID).first { $0.id == id }?.pointSize
        }

        func directDisplayID() throws -> CGDirectDisplayID {
            try CoreGraphicsDisplayService.directDisplayID(for: displayID)
        }

        /// Termination cleanup, then the safety net: the original mode committed permanently
        /// (Keep commits permanently, so a session-scoped restore would leave the kept mode in
        /// the display preferences), and the store emptied. The service downgrades to session
        /// scope by itself while the panel is still leaving a mirror set.
        func stop() {
            model.cleanupForTermination()
            _ = try? service.applyPreferringPermanent(modeID: originalModeID, to: displayID)
            store.allChoices.keys.forEach(store.removeChoice)
            store.setOriginalModeID(nil, forDisplayID: displayID)
        }
    }

    /// Polls `condition` on the main actor until it holds or `timeout` elapses.
    @discardableResult
    private func waitUntil(_ timeout: Duration, _ condition: () throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if try condition() { return true }
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: (a) native mode, revert

    @Test func nativeModeChangeRevertsToTheRecordedMode() async throws {
        let live = try Live()
        defer { live.stop() }
        let display = try live.display
        #expect(live.model.pendingConfirmation == nil)

        live.model.select(preset: .fullHD1080, for: display)
        #expect(live.model.lastError == nil)
        #expect(live.model.pendingConfirmation != nil)
        let switched = try await waitUntil(.seconds(5)) { try live.currentPointSize() == PixelSize(width: 1920, height: 1080) }
        #expect(switched, "main display did not reach 1920x1080 points")

        live.model.revertPending()
        #expect(live.model.lastError == nil)
        #expect(live.model.pendingConfirmation == nil)
        let restored = try await waitUntil(.seconds(5)) { try live.currentModeID() == live.originalModeID }
        #expect(restored, "main display did not return to mode \(live.originalModeID)")
        #expect(live.store.allChoices.isEmpty)
    }

    // MARK: (b) native mode, keep, then Native restores the recorded original

    @Test func nativeModeChangeKeptThenNativeRestoresTheOriginal() async throws {
        let live = try Live()
        defer { live.stop() }
        var display = try live.display

        live.model.select(preset: .fullHD1080, for: display)
        #expect(live.model.lastError == nil)
        try await waitUntil(.seconds(5)) { try live.currentPointSize() == PixelSize(width: 1920, height: 1080) }
        live.model.keepPending()
        #expect(live.model.lastError == nil)
        #expect(live.model.pendingConfirmation == nil)
        #expect(live.store.choice(forDisplayID: live.displayID)
            == DisplayChoice(preset: .fullHD1080, scaling: live.model.scaling))
        #expect(live.store.originalModeID(forDisplayID: live.displayID) == live.originalModeID)
        #expect(try live.currentPointSize() == PixelSize(width: 1920, height: 1080))

        // "Native" brings back the exact mode id the display had before ForceRes touched it,
        // even where the list holds byte-identical duplicates (ids 132/133 on the Odyssey).
        display = try live.display
        live.model.select(preset: nil, for: display)
        #expect(live.model.lastError == nil)
        #expect(live.model.pendingConfirmation != nil)
        live.model.keepPending()
        #expect(live.model.lastError == nil)
        let restored = try await waitUntil(.seconds(5)) { try live.currentModeID() == live.originalModeID }
        #expect(restored, "main display did not return to mode \(live.originalModeID)")
        #expect(live.store.choice(forDisplayID: live.displayID) == nil)
        #expect(live.store.originalModeID(forDisplayID: live.displayID) == live.originalModeID)
    }

    // MARK: (c) refresh rate: fixed 120, revert, then a no-op variable pick

    @Test func fixedRefreshRateRevertsToTheOriginalTwin() async throws {
        let live = try Live()
        defer { live.stop() }
        let display = try live.display
        let directID = try live.directDisplayID()
        let original = try #require(RefreshRateProbe.activeRefresh(for: directID))
        let state = live.model.refreshControlState(for: display)
        try #require(state.options.contains(.fixed(hertz: 120)), "main display does not enumerate 120 Hz here")
        #expect(state.isEnabled)

        live.model.select(refresh: .fixed(hertz: 120), for: display)
        #expect(live.model.lastError == nil)
        #expect(live.model.pendingConfirmation != nil)
        let switched = try await waitUntil(.seconds(5)) {
            guard let active = RefreshRateProbe.activeRefresh(for: directID) else { return false }
            return active.maxFPS == 120 && !active.isVariable
        }
        #expect(switched, "main display did not report fixed 120 Hz")
        #expect(try live.currentPointSize() == display.currentMode?.pointSize)

        live.model.revertPending()
        #expect(live.model.lastError == nil)
        #expect(live.model.pendingConfirmation == nil)
        let restored = try await waitUntil(.seconds(5)) { try live.currentModeID() == live.originalModeID }
        #expect(restored, "main display did not return to mode \(live.originalModeID)")
        let sameRefresh = try await waitUntil(.seconds(5)) {
            guard let active = RefreshRateProbe.activeRefresh(for: directID) else { return false }
            return active.maxFPS == original.maxFPS && active.isVariable == original.isVariable
        }
        #expect(sameRefresh, "refresh state did not return to \(original.maxFPS) Hz, variable \(original.isVariable)")
        #expect(live.store.allChoices.isEmpty)

        // Picking the state already in effect only records the choice: no countdown, no mode set.
        live.model.refresh()
        let settled = try live.display
        let current = live.model.refreshControlState(for: settled).current
        if original.isVariable, case .variable? = current {
            live.model.select(refresh: .variable, for: settled)
            #expect(live.model.pendingConfirmation == nil)
            #expect(try live.currentModeID() == live.originalModeID)
            #expect(live.store.choice(forDisplayID: live.displayID)?.refresh == .variable)
        } else if case .fixed(let hertz)? = current {
            live.model.select(refresh: .fixed(hertz: hertz), for: settled)
            #expect(live.model.pendingConfirmation == nil)
            #expect(try live.currentModeID() == live.originalModeID)
        }
    }

    // MARK: (d) virtual mirror, revert

    @Test(.enabled(if: LiveEnvironment.helperExists,
                   "forceres-vdhost is missing at \(LiveEnvironment.helperURL.path); run swift build first"))
    func virtualMirrorRevertsAndLeavesNoVirtualDisplay() async throws {
        let baselineOnline = try #require(LiveEnvironment.externalOnlineDisplayCount(),
                                          "forceres-probe is missing next to the helper; run swift build first")
        let live = try Live()
        defer { live.stop() }
        let display = try live.display
        let physical = try live.directDisplayID()
        #expect(CGDisplayMirrorsDisplay(physical) == kCGNullDirectDisplay)

        let plan = VirtualDisplayPlan(pixelSize: PixelSize(width: 1920, height: 1080), hiDPI: false,
                                      letterboxed: false, exceedsPanel: false)
        try live.model.applyVirtualMirror(preset: .fullHD1080, plan: plan, to: display)
        #expect(live.model.lastError == nil)
        #expect(live.controller.activeDisplayIDs.count == 1)
        #expect(live.model.activeVirtualMirrors[live.displayID]?.preset == .fullHD1080)
        #expect(live.model.pendingConfirmation != nil)
        #expect(live.model.displays.map(\.id).contains(live.displayID))
        #expect(!live.model.displays.contains { live.controller.activeDisplayIDs.contains($0.id) })
        let mirrored = try await waitUntil(.seconds(5)) {
            let physicalID = try live.directDisplayID()
            let pointSize = try live.currentPointSize()
            return CGDisplayMirrorsDisplay(physicalID) != kCGNullDirectDisplay
                && pointSize == PixelSize(width: 1920, height: 1080)
        }
        #expect(mirrored, "main display is not mirroring a 1920x1080 master")
        let mirroredDisplay = try live.display
        #expect(live.model.currentPreset(for: mirroredDisplay) == .fullHD1080)

        live.model.revertPending()
        #expect(live.model.lastError == nil)
        #expect(live.model.pendingConfirmation == nil)
        #expect(live.model.activeVirtualMirrors.isEmpty)
        #expect(live.controller.activeDisplayIDs.isEmpty)
        // Judge removal from a fresh process; the un-mirror itself takes several seconds to settle.
        let released = try await waitUntil(.seconds(20)) {
            let physicalID = try live.directDisplayID()
            return LiveEnvironment.externalOnlineDisplayCount() == baselineOnline
                && CGDisplayMirrorsDisplay(physicalID) == kCGNullDirectDisplay
        }
        #expect(released, "virtual display still online or main display still mirrored after 20 s")
        let restored = try await waitUntil(.seconds(10)) { try live.currentModeID() == live.originalModeID }
        #expect(restored, "macOS did not restore mode \(live.originalModeID) within 10 s")
        #expect(live.store.allChoices.isEmpty)

        // Termination cleanup is now a no-op.
        live.model.cleanupForTermination()
        #expect(live.model.lastError == nil)
        #expect(live.controller.activeDisplayIDs.isEmpty)
        #expect(LiveEnvironment.externalOnlineDisplayCount() == baselineOnline)
        #expect(try live.currentModeID() == live.originalModeID)
    }
}
