import CoreGraphics
import Foundation
import ForceResCore
import Testing
@testable import ForceResDisplay

@Suite("CoreGraphicsDisplayService (read-only)", .serialized)
struct CoreGraphicsDisplayServiceTests {
    let service = CoreGraphicsDisplayService()

    @Test func snapshotListsAtLeastOneDisplayWithUsableModes() throws {
        let displays = try service.snapshot()
        #expect(!displays.isEmpty)
        for display in displays {
            #expect(!display.id.isEmpty)
            #expect(!display.name.isEmpty)
            #expect(display.modes.contains { $0.isUsableForDesktopGUI }, "\(display.name) has no usable mode")
            #expect(display.nativePixelSize.width > 0 && display.nativePixelSize.height > 0)
            let current = try #require(display.currentModeID, "\(display.name) has no current mode id")
            #expect(display.modes.contains { $0.id == current }, "current mode \(current) missing from list")
            #expect(try service.currentModeID(for: display.id) == current)
            #expect(try service.modes(for: display.id).count == display.modes.count)
        }
    }

    @Test func onlineDisplayIDsMatchTheSnapshot() throws {
        #expect(service.onlineDisplayIDs() == (try service.snapshot().map(\.id)))
    }

    @Test func uuidRoundTripsToTheSameDirectDisplayID() throws {
        for cgID in CoreGraphicsDisplayService.onlineDisplayIDs() {
            let uuid = try #require(CoreGraphicsDisplayService.uuidString(for: cgID))
            #expect(try CoreGraphicsDisplayService.directDisplayID(for: uuid) == cgID)
        }
    }

    @Test func unknownUUIDIsReported() {
        #expect(throws: DisplayError.displayNotFound("00000000-0000-0000-0000-000000000000")) {
            try service.modes(for: "00000000-0000-0000-0000-000000000000")
        }
        #expect(throws: DisplayError.invalidDisplayUUID("nope")) {
            try service.modes(for: "nope")
        }
    }

    @Test func mirrorGuardRejectsUnregisteredMaster() throws {
        let physical = try #require(try service.snapshot().first?.id)
        let master = "11111111-2222-3333-4444-555555555555"
        // No virtual display is registered, so the guard must fire before any CG call.
        #expect(throws: DisplayError.unsafeMirrorDirection(master: master, mirror: physical)) {
            try service.setMirror(physicalDisplayID: physical, ofVirtualMasterID: master)
        }
    }

    @Test func mirrorGuardRejectsARegisteredVirtualDisplayAsTarget() throws {
        let registry = VirtualDisplayRegistry()
        let service = CoreGraphicsDisplayService(virtualDisplays: registry)
        registry.register("AAAAAAAA-0000-0000-0000-000000000001", cgID: 901)
        registry.register("AAAAAAAA-0000-0000-0000-000000000002", cgID: 902)
        #expect(throws: DisplayError.unsafeMirrorDirection(master: "AAAAAAAA-0000-0000-0000-000000000001",
                                                            mirror: "AAAAAAAA-0000-0000-0000-000000000002")) {
            try service.setMirror(physicalDisplayID: "AAAAAAAA-0000-0000-0000-000000000002",
                                  ofVirtualMasterID: "AAAAAAAA-0000-0000-0000-000000000001")
        }
    }

    @Test func resolveDisplayIDPrefersTheRegistryForOurVirtualDisplays() throws {
        let registry = VirtualDisplayRegistry()
        let service = CoreGraphicsDisplayService(virtualDisplays: registry)
        let uuid = "AAAAAAAA-0000-0000-0000-00000000000A"
        registry.register(uuid, cgID: 4242)
        #expect(try service.resolveDisplayID(for: uuid) == 4242)
        // Registered without an id: falls back to CoreGraphics, which validates the string.
        registry.register("not-a-uuid")
        #expect(throws: DisplayError.invalidDisplayUUID("not-a-uuid")) {
            try service.resolveDisplayID(for: "not-a-uuid")
        }
        // Unregistered: the ordinary online lookup applies.
        #expect(throws: DisplayError.displayNotFound("AAAAAAAA-0000-0000-0000-00000000000B")) {
            try service.resolveDisplayID(for: "AAAAAAAA-0000-0000-0000-00000000000B")
        }
    }

    @Test func mirrorMasterIsNilForUnmirroredDisplays() throws {
        for display in try service.snapshot() where display.isPhysical {
            #expect(service.mirrorMaster(of: display.id) == nil)
        }
        #expect(service.mirrorMaster(of: "nope") == nil)
    }
}

@Suite("PhysicalDisplayDetector")
struct PhysicalDisplayDetectorTests {
    static let odyssey = PhysicalDisplayDetector.Identity(vendor: 19501, product: 57397)

    @Test func matchesOnBothIDs() {
        let detector = PhysicalDisplayDetector(identities: [Self.odyssey])
        #expect(detector.isPhysical(vendor: 19501, model: 57397, isBuiltIn: false))
        #expect(!detector.isPhysical(vendor: 19501, model: 1, isBuiltIn: false))
        #expect(!detector.isPhysical(vendor: 1, model: 57397, isBuiltIn: false))
        #expect(!detector.isPhysical(vendor: VirtualDisplayController.vendorID, model: 0x0780_0438, isBuiltIn: false))
    }

    @Test func builtInPanelsArePhysicalWithoutARegistryMatch() {
        let detector = PhysicalDisplayDetector(identities: [])
        #expect(detector.isPhysical(vendor: 0, model: 0, isBuiltIn: true))
        #expect(!detector.isPhysical(vendor: 0, model: 0, isBuiltIn: false))
    }

    @Test func scanFindsEveryOnlineHardwareDisplay() throws {
        // On this Mac every online display is physical (no virtual display is running between tests).
        let detector = PhysicalDisplayDetector.scan()
        let displays = try CoreGraphicsDisplayService().snapshot()
        #expect(!displays.isEmpty)
        for display in displays {
            #expect(display.isPhysical, "\(display.name) should be physical; registry ids: \(detector.identities)")
        }
    }
}

@Suite("DisplayReconfigurationObserver")
struct DisplayReconfigurationObserverTests {
    /// Records scheduled flush blocks instead of running them after a real debounce delay, so a
    /// test can fire them back in a chosen order and exercise the generation-counter debounce logic
    /// deterministically, without depending on wall-clock timing or `Task.sleep`.
    final class FlushRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var blocks: [@Sendable () -> Void] = []

        func schedule(_ block: @escaping @Sendable () -> Void) {
            lock.lock()
            blocks.append(block)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return blocks.count
        }

        /// Fires and removes the earliest still-pending block. Returns `false` if none is pending.
        @discardableResult
        func fireOldest() -> Bool {
            lock.lock()
            guard !blocks.isEmpty else {
                lock.unlock()
                return false
            }
            let block = blocks.removeFirst()
            lock.unlock()
            block()
            return true
        }
    }

    /// An observer wired to a stream but not registered with CoreGraphics. Passing `scheduleFlush`
    /// replaces the real `DispatchQueue.asyncAfter` debounce with a caller-controlled scheduler.
    static func makeObserver(
        debounce: DispatchTimeInterval,
        scheduleFlush: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
    ) -> (DisplayReconfigurationObserver, AsyncStream<DisplayReconfiguration>) {
        var observer: DisplayReconfigurationObserver?
        let stream = AsyncStream<DisplayReconfiguration> { continuation in
            observer = DisplayReconfigurationObserver(continuation: continuation, debounce: debounce, scheduleFlush: scheduleFlush)
        }
        return (observer!, stream)
    }

    @Test func burstCoalescesIntoOneBeganAndOneEnded() async {
        let (observer, stream) = Self.makeObserver(debounce: .milliseconds(50))
        var iterator = stream.makeAsyncIterator()
        observer.handle(display: 1, flags: .beginConfigurationFlag)
        observer.handle(display: 2, flags: .beginConfigurationFlag)
        observer.handle(display: 1, flags: [.setModeFlag])
        observer.handle(display: 2, flags: [.setModeFlag, .movedFlag])
        #expect(await iterator.next() == .began)
        let expectedFlags = CGDisplayChangeSummaryFlags([.setModeFlag, .movedFlag]).rawValue
        guard case .ended(let ids, let flags) = await iterator.next() else {
            Issue.record("expected a single .ended event")
            return
        }
        #expect(flags == expectedFlags)
        // CoreGraphics synthesizes a UUID even for ids it does not know; only uniqueness is fixed.
        #expect(Set(ids).count == ids.count)
        #expect(ids.count <= 2)
    }

    @Test func aLaterCallbackPostponesTheFlush() async throws {
        // Drives the generation-counter debounce directly instead of racing real timers: recording
        // the scheduled flush blocks and firing them back in order exercises the same coalescing
        // logic without a wall-clock dependency that blocking work in other gated suites could starve.
        let recorder = FlushRecorder()
        let (observer, stream) = Self.makeObserver(debounce: .milliseconds(120)) { recorder.schedule($0) }
        var iterator = stream.makeAsyncIterator()

        observer.handle(display: 1, flags: [.setModeFlag])
        #expect(recorder.count == 1, "the first callback should schedule a flush")
        observer.handle(display: 1, flags: [.movedFlag])
        #expect(recorder.count == 2, "the second callback should schedule its own flush")

        // Firing the stale (first) scheduled flush must be a no-op: the generation counter
        // advanced when the second callback arrived, so the first timer's flush is rejected.
        #expect(recorder.fireOldest())
        // Firing the current (second) scheduled flush performs the real, coalesced flush.
        #expect(recorder.fireOldest())

        guard case .ended(_, let flags) = await iterator.next() else {
            Issue.record("expected a single .ended event")
            return
        }
        #expect(flags == CGDisplayChangeSummaryFlags([.setModeFlag, .movedFlag]).rawValue)
    }
}

@Suite("VirtualDisplayController", .serialized)
struct VirtualDisplayControllerTests {
    @Test func privateVirtualDisplayAPIResolvesOnThisMachine() {
        let (ok, missing) = VirtualDisplayController.isSupported
        #expect(ok, "missing symbols: \(missing.joined(separator: ", "))")
        #expect(missing.isEmpty)
    }

    @Test func identityIsDeterministic() {
        let size = PixelSize(width: 1920, height: 1080)
        let hiDPI = VirtualDisplayController.identity(for: size, hiDPI: true)
        let oneX = VirtualDisplayController.identity(for: size, hiDPI: false)
        #expect(hiDPI.productID == 125_830_200) // 1920 << 16 | 1080
        #expect(hiDPI.serialNumber == 2)
        #expect(oneX.productID == 125_830_200)
        #expect(oneX.serialNumber == 1)
        #expect(VirtualDisplayController.sizeInMillimeters(for: size, hiDPI: false) == CGSize(width: 443, height: 249))
        #expect(VirtualDisplayController.sizeInMillimeters(for: size, hiDPI: true) == CGSize(width: 443, height: 249))
    }
}

@Suite("MockDisplayService")
struct MockDisplayServiceTests {
    static let modeA = DisplayModeInfo(id: 10, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160,
                                       refreshRate: 60, ioFlags: 0x0200_0003, isUsableForDesktopGUI: true)
    static let modeB = DisplayModeInfo(id: 11, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080,
                                       refreshRate: 60, ioFlags: 3, isUsableForDesktopGUI: true)
    /// Valid but not safe (bit 0x2 clear).
    static let unsafeMode = DisplayModeInfo(id: 12, width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720,
                                            refreshRate: 60, ioFlags: 1, isUsableForDesktopGUI: false)
    static let display = DisplayInfo(id: "MOCK-1", name: "Mock", isBuiltIn: false, isMain: true,
                                     nativePixelSize: PixelSize(width: 3840, height: 2160),
                                     modes: [modeA, modeB, unsafeMode], currentModeID: 10)

    @Test func recordsAppliesAndUpdatesCurrentMode() throws {
        let mock = MockDisplayService(displays: [Self.display])
        #expect(try mock.apply(modeID: 11, to: "MOCK-1", persistence: .session) == .session)
        #expect(mock.appliedModes == [.init(modeID: 11, displayID: "MOCK-1", persistence: .session)])
        #expect(try mock.currentModeID(for: "MOCK-1") == 11)
        #expect(throws: DisplayError.modeNotFound(modeID: 99, displayID: "MOCK-1")) {
            try mock.apply(modeID: 99, to: "MOCK-1", persistence: .session)
        }
        #expect(throws: DisplayError.displayNotFound("nope")) {
            try mock.apply(modeID: 10, to: "nope", persistence: .session)
        }
    }

    @Test func refusesModesWithoutTheSafeFlag() throws {
        let mock = MockDisplayService(displays: [Self.display])
        #expect(throws: DisplayError.unsafeMode(modeID: 12)) {
            try mock.apply(modeID: 12, to: "MOCK-1", persistence: .session)
        }
        #expect(mock.appliedModes.isEmpty)
        #expect(try mock.currentModeID(for: "MOCK-1") == 10)
    }

    @Test func applyPreferringPermanentFallsBackToSession() throws {
        let mock = MockDisplayService(displays: [Self.display])
        #expect(try mock.applyPreferringPermanent(modeID: 11, to: "MOCK-1") == .permanent)
        mock.failPermanentApplies = true
        #expect(try mock.applyPreferringPermanent(modeID: 10, to: "MOCK-1") == .session)
        #expect(mock.appliedModes.map(\.persistence) == [.permanent, .session])
    }

    @Test func activeMirrorSetDowngradesPermanentToSession() throws {
        let mock = MockDisplayService(displays: [Self.display])
        mock.mirrorSetActive = true
        #expect(try mock.apply(modeID: 11, to: "MOCK-1", persistence: .permanent) == .session)
        #expect(try mock.applyPreferringPermanent(modeID: 10, to: "MOCK-1") == .session)
        #expect(mock.appliedModes.map(\.persistence) == [.session, .session])
        mock.mirrorSetActive = false
        #expect(try mock.applyPreferringPermanent(modeID: 11, to: "MOCK-1") == .permanent)
    }

    @Test func recordsMirrorChangesAndReportsTheMaster() throws {
        let mock = MockDisplayService(displays: [Self.display])
        #expect(mock.onlineDisplayIDs() == ["MOCK-1"])
        #expect(mock.mirrorMaster(of: "MOCK-1") == nil)
        try mock.setMirror(physicalDisplayID: "MOCK-1", ofVirtualMasterID: "VIRT")
        #expect(mock.mirrorMaster(of: "MOCK-1") == "VIRT")
        try mock.removeMirror(physicalDisplayID: "MOCK-1")
        #expect(mock.mirrorMaster(of: "MOCK-1") == nil)
        #expect(mock.mirrorChanges == [.init(physicalDisplayID: "MOCK-1", masterID: "VIRT"),
                                       .init(physicalDisplayID: "MOCK-1", masterID: nil)])
    }

    @Test func replaceDisplaysEmitsReconfiguration() async throws {
        let mock = MockDisplayService(displays: [Self.display])
        let stream = mock.reconfigurations()
        var iterator = stream.makeAsyncIterator()
        mock.replaceDisplays([])
        let event = await iterator.next()
        #expect(event == .ended(displayIDs: [], flags: 0))
        #expect(try mock.snapshot().isEmpty)
    }
}
