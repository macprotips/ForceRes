import CoreGraphics
import Foundation
import ForceResCore
import Synchronization
import Testing
@testable import ForceResDisplay

@Suite("VirtualDisplayHostProtocol.Request")
struct RequestArgumentsTests {
    @Test func roundTripsA1xRequest() throws {
        let request = VirtualDisplayHostProtocol.Request(
            width: 1920, height: 1080, hiDPI: false, name: "ForceRes Test",
            vendorID: 0x4652, productID: 7, serialNumber: 1,
            millimetersWidth: 443, millimetersHeight: 249)
        let parsed = try VirtualDisplayHostProtocol.Request.parse(arguments: request.arguments)
        #expect(parsed == request)
        #expect(!request.arguments.contains("--hidpi"))
    }

    @Test func roundTripsAHiDPIRequestWithASpacedName() throws {
        let request = VirtualDisplayHostProtocol.Request(
            width: 3840, height: 2160, hiDPI: true, name: "ForceRes Virtual Display 2",
            vendorID: 0x4652, productID: 99, serialNumber: 2,
            millimetersWidth: 443, millimetersHeight: 249)
        let parsed = try VirtualDisplayHostProtocol.Request.parse(arguments: request.arguments)
        #expect(parsed == request)
        #expect(request.arguments.contains("--hidpi"))
    }
}

@Suite("VirtualDisplayHostProtocol.Request parse errors")
struct RequestParseErrorTests {
    /// A complete, valid argument list to mutate for individual error cases.
    static func baseArguments(hiDPI: Bool = false) -> [String] {
        var args = ["--width", "1920", "--height", "1080", "--name", "Display",
                    "--vendor", "1", "--product", "2", "--serial", "3", "--mm", "443x249"]
        if hiDPI { args.append("--hidpi") }
        return args
    }

    @Test func unknownFlagIsRejected() {
        #expect(throws: VirtualDisplayHostProtocol.ArgumentError.unknownFlag(flag: "--bogus")) {
            try VirtualDisplayHostProtocol.Request.parse(arguments: ["--bogus", "1"])
        }
    }

    @Test func missingValueIsRejected() {
        #expect(throws: VirtualDisplayHostProtocol.ArgumentError.missingValue(flag: "--width")) {
            try VirtualDisplayHostProtocol.Request.parse(arguments: ["--width"])
        }
    }

    @Test func duplicateFlagIsRejected() {
        var args = Self.baseArguments()
        args.append(contentsOf: ["--width", "100"])
        #expect(throws: VirtualDisplayHostProtocol.ArgumentError.duplicateFlag(flag: "--width")) {
            try VirtualDisplayHostProtocol.Request.parse(arguments: args)
        }
    }

    @Test func missingRequiredFlagIsRejected() {
        let args = ["--height", "1080", "--name", "Display",
                    "--vendor", "1", "--product", "2", "--serial", "3", "--mm", "443x249"]
        #expect(throws: VirtualDisplayHostProtocol.ArgumentError.missingFlag(flag: "--width")) {
            try VirtualDisplayHostProtocol.Request.parse(arguments: args)
        }
    }

    @Test(arguments: ["abc", "0", "-1", "\(VirtualDisplayHostProtocol.maximumDimension + 1)"])
    func nonNumericZeroOrOverMaximumWidthIsRejected(_ value: String) {
        var args = Self.baseArguments()
        args[1] = value
        #expect(throws: VirtualDisplayHostProtocol.ArgumentError.invalidValue(flag: "--width", value: value)) {
            try VirtualDisplayHostProtocol.Request.parse(arguments: args)
        }
    }

    @Test func oddDimensionsWithHiDPIAreRejected() {
        var args = Self.baseArguments(hiDPI: true)
        args[1] = "1921"
        #expect(throws: VirtualDisplayHostProtocol.ArgumentError.invalidValue(
            flag: "--hidpi", value: "1921x1080 is not divisible by 2")) {
            try VirtualDisplayHostProtocol.Request.parse(arguments: args)
        }
    }

    @Test(arguments: ["443", "443x", "0x10", "ax b"])
    func badMillimeterFormatsAreRejected(_ value: String) {
        var args = Self.baseArguments()
        args[args.count - 1] = value
        #expect(throws: VirtualDisplayHostProtocol.ArgumentError.invalidValue(flag: "--mm", value: value)) {
            try VirtualDisplayHostProtocol.Request.parse(arguments: args)
        }
    }

    @Test func emptyNameIsRejected() {
        var args = Self.baseArguments()
        args[5] = ""
        #expect(throws: VirtualDisplayHostProtocol.ArgumentError.invalidValue(flag: "--name", value: "")) {
            try VirtualDisplayHostProtocol.Request.parse(arguments: args)
        }
    }

    @Test func errorDescriptionsAreNonEmpty() {
        let errors: [VirtualDisplayHostProtocol.ArgumentError] = [
            .unknownFlag(flag: "--x"), .missingValue(flag: "--x"), .duplicateFlag(flag: "--x"),
            .missingFlag(flag: "--x"), .invalidValue(flag: "--x", value: "y"),
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
    }
}

@Suite("VirtualDisplayHostProtocol.Request sizing")
struct RequestSizingTests {
    @Test func hiDPILooksLikeAndExpectedPointSize() {
        let request = VirtualDisplayHostProtocol.Request(
            width: 3840, height: 2160, hiDPI: true, name: "D",
            vendorID: 1, productID: 1, serialNumber: 1, millimetersWidth: 1, millimetersHeight: 1)
        #expect(request.looksLikeSize == PixelSize(width: 1920, height: 1080))
        #expect(request.expectedPointSize == PixelSize(width: 1920, height: 1080))
    }

    @Test func oneXHasNoLooksLikeSize() {
        let request = VirtualDisplayHostProtocol.Request(
            width: 1920, height: 1080, hiDPI: false, name: "D",
            vendorID: 1, productID: 1, serialNumber: 1, millimetersWidth: 1, millimetersHeight: 1)
        #expect(request.looksLikeSize == nil)
        #expect(request.expectedPointSize == PixelSize(width: 1920, height: 1080))
    }
}

@Suite("VirtualDisplayHostProtocol.Reply")
struct ReplyTests {
    @Test func publishedRoundTrips() throws {
        let published = VirtualDisplayHostProtocol.Published(
            displayID: 42, uuid: "ABCD-1234", pointsWidth: 1920, pointsHeight: 1080,
            pixelsWidth: 3840, pixelsHeight: 2160)
        let line = VirtualDisplayHostProtocol.Reply.published(published).line
        #expect(line.hasSuffix("\n"))
        #expect(line.dropLast().last != "\n")
        #expect(line.filter { $0 == "\n" }.count == 1)
        let decoded = try VirtualDisplayHostProtocol.Reply.decode(line: line)
        #expect(decoded == .published(published))
    }

    @Test func failedRoundTrips() throws {
        let line = VirtualDisplayHostProtocol.Reply.failed("boom").line
        #expect(line.hasSuffix("\n"))
        #expect(line.filter { $0 == "\n" }.count == 1)
        let decoded = try VirtualDisplayHostProtocol.Reply.decode(line: line)
        #expect(decoded == .failed("boom"))
    }

    @Test func decodingEmptyOrWhitespaceIsEmpty() {
        #expect(throws: VirtualDisplayHostProtocol.CodecError.empty) {
            try VirtualDisplayHostProtocol.Reply.decode(line: "")
        }
        #expect(throws: VirtualDisplayHostProtocol.CodecError.empty) {
            try VirtualDisplayHostProtocol.Reply.decode(line: "   \n")
        }
    }

    @Test func decodingNonJSONReportsTheOffendingText() {
        #expect(throws: VirtualDisplayHostProtocol.CodecError.notJSONObject("not json")) {
            try VirtualDisplayHostProtocol.Reply.decode(line: "not json")
        }
    }

    @Test func decodingMissingUUIDFails() {
        #expect(throws: VirtualDisplayHostProtocol.CodecError.missingField("uuid")) {
            try VirtualDisplayHostProtocol.Reply.decode(
                line: #"{"displayID":1,"pointsWidth":1,"pointsHeight":1,"pixelsWidth":1,"pixelsHeight":1}"#)
        }
    }

    @Test func decodingMissingNumericFieldFails() {
        #expect(throws: VirtualDisplayHostProtocol.CodecError.missingField("pointsWidth")) {
            try VirtualDisplayHostProtocol.Reply.decode(
                line: #"{"uuid":"X","displayID":1,"pointsHeight":1,"pixelsWidth":1,"pixelsHeight":1}"#)
        }
    }

    @Test("A displayID outside UInt32 is rejected and the bad line is reported",
          arguments: ["\(UInt64(UInt32.max) + 1)", "-1"])
    func decodingDisplayIDOutOfUInt32RangeIsRejected(value: String) throws {
        let line = #"{"uuid":"X","displayID":\#(value),"pointsWidth":1,"pointsHeight":1,"pixelsWidth":1,"pixelsHeight":1}"#
        let error = try #require(throws: VirtualDisplayHostProtocol.CodecError.self) {
            try VirtualDisplayHostProtocol.Reply.decode(line: line)
        }
        // Foundation reports an out-of-range integer without naming the field, so the whole line
        // is carried instead.
        #expect(error == .notJSONObject(line))
        #expect(error.errorDescription?.contains(value) == true)
    }

    @Test func extraUnknownKeysAreIgnored() throws {
        let decoded = try VirtualDisplayHostProtocol.Reply.decode(
            line: #"{"uuid":"X","displayID":1,"pointsWidth":1,"pointsHeight":2,"pixelsWidth":3,"pixelsHeight":4,"extra":"ignored"}"#)
        #expect(decoded == .published(VirtualDisplayHostProtocol.Published(
            displayID: 1, uuid: "X", pointsWidth: 1, pointsHeight: 2, pixelsWidth: 3, pixelsHeight: 4)))
    }
}

@Suite("VirtualDisplayHostProtocol.resolveHelperURL")
struct ResolveHelperURLTests {
    static let auxiliary = URL(fileURLWithPath: "/aux/forceres-vdhost")
    static let sibling = URL(fileURLWithPath: "/exe-dir/forceres-vdhost")
    static let executable = URL(fileURLWithPath: "/exe-dir/ForceRes")

    @Test func prefersAuxiliaryWhenExecutable() {
        let resolved = VirtualDisplayHostProtocol.resolveHelperURL(
            auxiliaryExecutableURL: Self.auxiliary, executableURL: Self.executable,
            isExecutableFile: { $0 == Self.auxiliary || $0 == Self.sibling })
        #expect(resolved == Self.auxiliary)
    }

    @Test func fallsBackToSiblingOfExecutableURL() {
        let resolved = VirtualDisplayHostProtocol.resolveHelperURL(
            auxiliaryExecutableURL: Self.auxiliary, executableURL: Self.executable,
            isExecutableFile: { $0 == Self.sibling })
        #expect(resolved == Self.sibling)
    }

    @Test func returnsNilWhenNeitherIsExecutable() {
        let resolved = VirtualDisplayHostProtocol.resolveHelperURL(
            auxiliaryExecutableURL: Self.auxiliary, executableURL: Self.executable,
            isExecutableFile: { _ in false })
        #expect(resolved == nil)
    }

    @Test func handlesNilInputs() {
        let resolved = VirtualDisplayHostProtocol.resolveHelperURL(
            auxiliaryExecutableURL: nil, executableURL: nil, isExecutableFile: { _ in true })
        #expect(resolved == nil)
    }
}

@Suite("VirtualDisplayController.request")
struct ControllerRequestTests {
    @Test func hiDPI1920x1080RequestMatchesExpectedFields() {
        let size = PixelSize(width: 1920, height: 1080)
        let request = VirtualDisplayController.request(name: "ForceRes Test", pixelSize: size, hiDPI: true)
        #expect(request == VirtualDisplayHostProtocol.Request(
            width: 3840, height: 2160, hiDPI: true, name: "ForceRes Test",
            vendorID: 0x4652, productID: 125_830_200, serialNumber: 2,
            millimetersWidth: 443, millimetersHeight: 249))
        #expect(request.looksLikeSize == PixelSize(width: 1920, height: 1080))
    }

    @Test func oneX1920x1080RequestMatchesExpectedFields() {
        let size = PixelSize(width: 1920, height: 1080)
        let request = VirtualDisplayController.request(name: "ForceRes Test", pixelSize: size, hiDPI: false)
        #expect(request == VirtualDisplayHostProtocol.Request(
            width: 1920, height: 1080, hiDPI: false, name: "ForceRes Test",
            vendorID: 0x4652, productID: 125_830_200, serialNumber: 1,
            millimetersWidth: 443, millimetersHeight: 249))
        #expect(request.looksLikeSize == nil)
    }

    @Test func backingSizeForBothModes() {
        let size = PixelSize(width: 1920, height: 1080)
        #expect(VirtualDisplayController.backingSize(for: size, hiDPI: true) == PixelSize(width: 3840, height: 2160))
        #expect(VirtualDisplayController.backingSize(for: size, hiDPI: false) == size)
    }
}

@Suite("VirtualDisplayController helper resolution")
struct ControllerHelperResolutionTests {
    @Test func nonExecutableExplicitHelperURLIsReportedAsMissing() throws {
        let nonExecutable = URL(fileURLWithPath: "/dev/null/forceres-vdhost-does-not-exist")
        let registry = VirtualDisplayRegistry()
        let service = MockDisplayService(displays: [])
        let controller = VirtualDisplayController(service: service, registry: registry, helperURL: nonExecutable)

        #expect(throws: DisplayError.helperMissing) {
            try controller.helperURL()
        }
        #expect(throws: DisplayError.helperMissing) {
            try controller.create(name: "X", pixelSize: PixelSize(width: 1920, height: 1080), hiDPI: false,
                                  physicalDisplayID: "PHYS")
        }
        #expect(controller.activeDisplayIDs.isEmpty)
        #expect(registry.all.isEmpty)
        #expect(DisplayError.helperMissing.errorDescription == "ForceRes is missing its display helper; reinstall the app.")
    }
}

// MARK: - Fake helpers (/bin/sh)

/// Anchors `Bundle(for:)` to this test bundle.
private final class TestBundleMarker {}

enum FakeHelper {
    /// A `/bin/sh` process running `script`. `readsStdin` scripts must consume stdin themselves.
    static func process(_ script: String) -> HelperProcess {
        HelperProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    }

    /// A shell command that prints a valid `published` reply for `uuid`.
    static func publishCommand(uuid: String, displayID: UInt32 = 4242) -> String {
        let reply = VirtualDisplayHostProtocol.Reply.published(.init(
            displayID: displayID, uuid: uuid, pointsWidth: 1920, pointsHeight: 1080,
            pixelsWidth: 1920, pixelsHeight: 1080)).line
        return "printf '%s' '\(reply)'"
    }

    /// A one-line script file with the shebang, so it can be handed to the controller as the helper.
    static func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("forceres-fake-helper-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }
}

@Suite("HelperProcess", .serialized)
struct HelperProcessTests {
    @Test func readsTheFirstLineAndIgnoresTheRest() throws {
        let helper = FakeHelper.process("echo first; echo second; sleep 5")
        try helper.launch()
        defer { helper.stop(gracePeriod: 1) }
        #expect(helper.readFirstLine(timeout: 3) == "first")
        #expect(helper.readFirstLine(timeout: 0.1) == "first")
    }

    @Test func eofWithoutALineIsNil() throws {
        let helper = FakeHelper.process("exit 0")
        try helper.launch()
        #expect(helper.readFirstLine(timeout: 3) == nil)
        #expect(FakeHelper.waitUntil(2) { !helper.isRunning })
    }

    @Test func timeoutWithoutALineIsNil() throws {
        let helper = FakeHelper.process("sleep 5")
        try helper.launch()
        let start = Date()
        #expect(helper.readFirstLine(timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) >= 0.3)
        helper.stop(gracePeriod: 1)
        #expect(!helper.isRunning)
    }

    @Test func exitBeforeALineReportsUnexpectedExitWithStatus() throws {
        let helper = FakeHelper.process("sleep 0.1; exit 3")
        let status = Mutex<Int32?>(nil)
        helper.onUnexpectedExit = { code in status.withLock { $0 = code } }
        try helper.launch()
        #expect(helper.readFirstLine(timeout: 3) == nil)
        #expect(FakeHelper.waitUntil(2) { status.withLock { $0 } != nil })
        #expect(status.withLock { $0 } == 3)
    }

    @Test func stdinEOFEndsACooperativeHelperWithoutSignals() throws {
        let helper = FakeHelper.process("echo ready; read line; exit 0")
        let unexpected = Mutex(false)
        helper.onUnexpectedExit = { _ in unexpected.withLock { $0 = true } }
        try helper.launch()
        #expect(helper.readFirstLine(timeout: 3) == "ready")
        let start = Date()
        helper.stop(gracePeriod: 2)
        #expect(!helper.isRunning)
        #expect(Date().timeIntervalSince(start) < HelperProcess.stdinCloseGracePeriod)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(!unexpected.withLock { $0 })
    }

    @Test func stopIsIdempotent() throws {
        let helper = FakeHelper.process("sleep 5")
        try helper.launch()
        helper.stop(gracePeriod: 1)
        #expect(!helper.isRunning)
        helper.stop(gracePeriod: 1)
        #expect(!helper.isRunning)
    }

    @Test func sigkillEndsAHelperThatIgnoresSIGTERM() throws {
        let helper = FakeHelper.process("trap '' TERM; while :; do sleep 0.1; done")
        try helper.launch()
        Thread.sleep(forTimeInterval: 0.2) // let the trap install
        let start = Date()
        helper.stop(gracePeriod: 0.3)
        let elapsed = Date().timeIntervalSince(start)
        #expect(!helper.isRunning)
        #expect(elapsed >= HelperProcess.stdinCloseGracePeriod + 0.3, "SIGKILL should follow both grace periods (\(elapsed)s)")
    }

    @Test func stopBeforeLaunchIsHarmless() {
        let helper = FakeHelper.process("exit 0")
        helper.stop(gracePeriod: 1)
        #expect(!helper.isRunning)
        #expect(helper.processIdentifier == 0)
    }
}

@Suite("VirtualDisplayController with fake helpers", .serialized)
struct VirtualDisplayControllerFakeHelperTests {
    static let uuid = "FAKE-VD-0001"
    static let physical = DisplayInfo(id: "PHYS-1", name: "Physical", isBuiltIn: false, isMain: true,
                                      nativePixelSize: PixelSize(width: 3840, height: 2160), modes: [], currentModeID: nil)
    static let virtualInfo = DisplayInfo(id: uuid, name: "Virtual", isBuiltIn: false, isMain: false,
                                         nativePixelSize: PixelSize(width: 1920, height: 1080), modes: [], currentModeID: nil,
                                         isPhysical: false)

    @Test func helperThatExitsRightAfterPublishingLeavesNoEntry() throws {
        let script = try FakeHelper.script("\(FakeHelper.publishCommand(uuid: Self.uuid)); exit 3")
        defer { try? FileManager.default.removeItem(at: script) }
        let registry = VirtualDisplayRegistry()
        let service = MockDisplayService(displays: [Self.physical, Self.virtualInfo])
        let controller = VirtualDisplayController(service: service, registry: registry, helperURL: script)

        // Either the exit is seen before `create` returns (it throws) or the unexpected-exit
        // callback cleans up moments later; both must leave nothing behind.
        do {
            let created = try controller.create(name: "Fake", pixelSize: PixelSize(width: 1920, height: 1080),
                                                hiDPI: false, physicalDisplayID: "PHYS-1")
            #expect(created == Self.uuid)
        } catch let error as DisplayError {
            guard case .virtualDisplayCreationFailed = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
        #expect(FakeHelper.waitUntil(3) { controller.activeDisplayIDs.isEmpty && registry.all.isEmpty })
        #expect(controller.activeDisplayIDs.isEmpty)
        #expect(registry.all.isEmpty)
        #expect(controller.lastWarnings.contains { $0.hasPrefix("Helper for \(Self.uuid)") }, "\(controller.lastWarnings)")
    }

    @Test func destroyUnmirrorsThroughTheServiceAndEndsTheHelper() throws {
        let script = try FakeHelper.script("\(FakeHelper.publishCommand(uuid: Self.uuid)); read line; exit 0")
        defer { try? FileManager.default.removeItem(at: script) }
        let registry = VirtualDisplayRegistry()
        let service = MockDisplayService(displays: [Self.physical, Self.virtualInfo])
        let controller = VirtualDisplayController(service: service, registry: registry, helperURL: script)

        let created = try controller.create(name: "Fake", pixelSize: PixelSize(width: 1920, height: 1080),
                                            hiDPI: false, physicalDisplayID: "PHYS-1")
        #expect(created == Self.uuid)
        #expect(controller.activeDisplayIDs == [Self.uuid])
        #expect(registry.cgID(for: Self.uuid) == 4242)
        #expect(controller.lastWarnings.isEmpty, "\(controller.lastWarnings)")

        try service.setMirror(physicalDisplayID: "PHYS-1", ofVirtualMasterID: Self.uuid)
        controller.destroy(displayID: Self.uuid)

        #expect(service.mirrorChanges.last == .init(physicalDisplayID: "PHYS-1", masterID: nil))
        #expect(service.mirrorMaster(of: "PHYS-1") == nil)
        #expect(controller.activeDisplayIDs.isEmpty)
        #expect(registry.all.isEmpty)
        // Destroying again is a no-op.
        controller.destroy(displayID: Self.uuid)
        #expect(service.mirrorChanges.count == 2)
    }

    @Test func failedReplyStopsTheHelperAndThrows() throws {
        let script = try FakeHelper.script("printf '%s\\n' '{\"error\":\"no can do\"}'; read line")
        defer { try? FileManager.default.removeItem(at: script) }
        let registry = VirtualDisplayRegistry()
        let service = MockDisplayService(displays: [Self.physical])
        let controller = VirtualDisplayController(service: service, registry: registry, helperURL: script)
        #expect(throws: DisplayError.virtualDisplayCreationFailed("no can do")) {
            try controller.create(name: "Fake", pixelSize: PixelSize(width: 1920, height: 1080),
                                  hiDPI: false, physicalDisplayID: "PHYS-1")
        }
        #expect(controller.activeDisplayIDs.isEmpty)
        #expect(registry.all.isEmpty)
    }
}

// MARK: - Live helper suite

@Suite("VirtualDisplayController live helper", .serialized)
struct VirtualDisplayControllerLiveHelperTests {
    /// Locates the built `forceres-vdhost`. `VirtualDisplayHostProtocol.locateHelper()` cannot find
    /// it from inside an xctest bundle, so look next to this test bundle (the SwiftPM products
    /// directory), then fall back to `.build/debug` relative to the repository root.
    static var helperURL: URL? {
        let name = VirtualDisplayHostProtocol.executableName
        var candidates: [URL] = []
        candidates.append(Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent(name))
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            candidates.append(dir.appendingPathComponent(".build/debug/\(name)"))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func makeController() -> (VirtualDisplayController, CoreGraphicsDisplayService)? {
        guard let helperURL else { return nil }
        let registry = VirtualDisplayRegistry()
        let service = CoreGraphicsDisplayService(virtualDisplays: registry)
        return (VirtualDisplayController(service: service, registry: registry, helperURL: helperURL), service)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FORCERES_LIVE_TESTS"] == "1"))
    func createdVirtualDisplayIsNotPhysicalButTheOdysseyIs() throws {
        guard let (controller, service) = Self.makeController() else {
            Issue.record("forceres-vdhost helper not found; build it first")
            return
        }
        let before = try service.snapshot()
        let allPhysical = before.allSatisfy { $0.isPhysical }
        #expect(allPhysical, "\(before.map { ($0.name, $0.isPhysical) })")

        let uuid = try controller.create(name: "ForceRes Live Physical Check", pixelSize: PixelSize(width: 1920, height: 1080),
                                         hiDPI: false, physicalDisplayID: before[0].id)
        defer {
            controller.destroy(displayID: uuid)
            _ = FakeHelper.waitUntil(5) { !CoreGraphicsDisplayService.onlineDisplayIDs().contains(registryID(uuid)) }
        }
        func registryID(_ id: String) -> CGDirectDisplayID { controller.registry.cgID(for: id) ?? 0 }
        let cgID = try #require(controller.registry.cgID(for: uuid))
        let detector = PhysicalDisplayDetector.scan()
        #expect(!detector.isPhysical(cgID), "virtual display \(uuid) reported as physical")
        #expect(CGDisplayVendorNumber(cgID) == VirtualDisplayController.vendorID)
        let after = try service.snapshot()
        #expect(after.first { $0.id == uuid }?.isPhysical == false)
        for display in after where display.id != uuid {
            #expect(display.isPhysical, "\(display.name) lost its physical flag")
        }
        // The mirror guard refuses the virtual display as a target even when it is registered as
        // ours (registry guard) and refuses an unregistered id as master before touching CG.
        #expect(throws: DisplayError.unsafeMirrorDirection(master: uuid, mirror: uuid)) {
            try service.setMirror(physicalDisplayID: uuid, ofVirtualMasterID: uuid)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FORCERES_LIVE_TESTS"] == "1"))
    func oneXCreateAndDestroy() throws {
        guard let (controller, service) = Self.makeController() else {
            Issue.record("forceres-vdhost helper not found; build it first")
            return
        }
        let baseline = CoreGraphicsDisplayService.onlineDisplayIDs().count
        let physical = try #require(try service.snapshot().first?.id)

        let uuid = try controller.create(name: "ForceRes Live Test 1x", pixelSize: PixelSize(width: 1920, height: 1080),
                                         hiDPI: false, physicalDisplayID: physical)
        #expect(controller.activeDisplayIDs == [uuid])
        #expect(controller.lastWarnings.isEmpty, "\(controller.lastWarnings)")
        let cgID = try CoreGraphicsDisplayService.directDisplayID(for: uuid)
        let bounds = CGDisplayBounds(cgID)
        #expect(bounds.width == 1920)
        #expect(bounds.height == 1080)

        controller.destroy(displayID: uuid)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, CoreGraphicsDisplayService.onlineDisplayIDs().count > baseline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        #expect(CoreGraphicsDisplayService.onlineDisplayIDs().count == baseline, "virtual display leaked")
        #expect(controller.activeDisplayIDs.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FORCERES_LIVE_TESTS"] == "1"))
    func hiDPICreateAndDestroy() throws {
        guard let (controller, service) = Self.makeController() else {
            Issue.record("forceres-vdhost helper not found; build it first")
            return
        }
        let baseline = CoreGraphicsDisplayService.onlineDisplayIDs().count
        let physical = try #require(try service.snapshot().first?.id)

        let uuid = try controller.create(name: "ForceRes Live Test HiDPI", pixelSize: PixelSize(width: 1920, height: 1080),
                                         hiDPI: true, physicalDisplayID: physical)
        #expect(controller.lastWarnings.isEmpty, "\(controller.lastWarnings)")
        let cgID = try CoreGraphicsDisplayService.directDisplayID(for: uuid)
        let bounds = CGDisplayBounds(cgID)
        #expect(bounds.width == 1920)
        #expect(bounds.height == 1080)

        controller.destroy(displayID: uuid)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, CoreGraphicsDisplayService.onlineDisplayIDs().count > baseline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        #expect(CoreGraphicsDisplayService.onlineDisplayIDs().count == baseline, "virtual display leaked")
        #expect(controller.activeDisplayIDs.isEmpty)
    }
}
