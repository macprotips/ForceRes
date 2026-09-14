import CoreGraphics
import Foundation
import ForceResCore
import Synchronization
import VirtualDisplayBridge

/// Creates and tears down ForceRes virtual displays (Tier 2) by supervising one `forceres-vdhost`
/// helper process per display. Knows nothing about presets: the caller supplies the preset's
/// pixel size and whether the 2x "looks like" variant is wanted.
///
/// Why a helper: a `CGVirtualDisplay` that has ever been a mirror master is only removed when
/// its owning process exits, and a process that enumerated display modes before creating a
/// virtual display can never enumerate that display's modes (docs/RESEARCH.md, addendum). So
/// the app never owns a virtual display; "destroy" means "end the helper".
///
/// Thread-safe (lock-protected). Every display query and mirror change goes through the injected
/// `DisplayService`, so the mirror-direction guard applies everywhere and the controller is
/// testable with `MockDisplayService`.
public final class VirtualDisplayController: Sendable {
    /// Fixed EDID vendor id ("FR"). Product id and serial are derived from the requested size so
    /// macOS remembers the arrangement of "the same" display across launches.
    public static let vendorID: UInt32 = 0x4652

    /// Result of the runtime check for the private `CGVirtualDisplay` classes. The helper runs
    /// the same check in its own process; a missing helper binary is reported by `create`.
    public static var isSupported: (Bool, missingSymbols: [String]) {
        var missing: NSArray?
        let ok = FRVirtualDisplayBridge.isSupported(withMissingSymbols: &missing)
        return (ok, (missing as? [String]) ?? [])
    }

    /// How long `destroy` waits for a helper to exit after SIGTERM before sending SIGKILL.
    static let helperExitGracePeriod: TimeInterval = 2

    private struct Entry {
        let helper: HelperProcess
        let cgID: CGDirectDisplayID
        let uuid: String
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var warnings: [String] = []
    }

    private let service: any DisplayService
    /// Registry shared with the `DisplayService` that enforces the mirror-direction rule.
    public let registry: VirtualDisplayRegistry
    private let state = Mutex(State())
    private let explicitHelperURL: URL?

    /// How long `create` waits for the helper to report the display online (the helper itself
    /// waits up to 3 s for CoreGraphics; the supervisor allows `onlineTimeout + 2` for the reply).
    public let onlineTimeout: TimeInterval

    /// - Parameters:
    ///   - service: used to dissolve mirrors before destruction.
    ///   - registry: must be the same instance the service was created with.
    ///   - onlineTimeout: see `onlineTimeout`.
    ///   - helperURL: explicit path of the `forceres-vdhost` executable; nil locates it
    ///     automatically (app bundle auxiliary executable, then next to the running executable).
    public init(service: any DisplayService, registry: VirtualDisplayRegistry, onlineTimeout: TimeInterval = 3,
                helperURL: URL? = nil) {
        self.service = service
        self.registry = registry
        self.onlineTimeout = onlineTimeout
        self.explicitHelperURL = helperURL
    }

    /// UUIDs of the virtual displays this controller currently owns.
    public var activeDisplayIDs: [String] { state.withLock { $0.entries.keys.sorted() } }

    /// Non-fatal observations from the most recent `create` (for example unexpected geometry).
    public var lastWarnings: [String] { state.withLock { $0.warnings } }

    /// Deterministic (productID, serialNumber) for a given preset size and scaling.
    static func identity(for pixelSize: PixelSize, hiDPI: Bool) -> (productID: UInt32, serialNumber: UInt32) {
        let product = (UInt32(clamping: pixelSize.width) & 0xFFFF) << 16 | (UInt32(clamping: pixelSize.height) & 0xFFFF)
        return (product, hiDPI ? 2 : 1)
    }

    /// Physical size that makes macOS treat the panel as ~110 dpi in points: the 1x framebuffer
    /// at 110 dpi, or the 2x backing (`2 * pixelSize`) at 220 dpi, which is the same number.
    static func sizeInMillimeters(for pixelSize: PixelSize, hiDPI: Bool) -> CGSize {
        let backing = Self.backingSize(for: pixelSize, hiDPI: hiDPI)
        let dpi = hiDPI ? 220.0 : 110.0
        return CGSize(width: (Double(backing.width) / dpi * 25.4).rounded(),
                      height: (Double(backing.height) / dpi * 25.4).rounded())
    }

    /// Backing pixel size the helper is launched with: `2 * pixelSize` for HiDPI, else `pixelSize`.
    static func backingSize(for pixelSize: PixelSize, hiDPI: Bool) -> PixelSize {
        hiDPI ? PixelSize(width: pixelSize.width * 2, height: pixelSize.height * 2) : pixelSize
    }

    /// The helper request for a preset size. Pure; used by `create` and by tests.
    static func request(name: String, pixelSize: PixelSize, hiDPI: Bool) -> VirtualDisplayHostProtocol.Request {
        let backing = backingSize(for: pixelSize, hiDPI: hiDPI)
        let identity = identity(for: pixelSize, hiDPI: hiDPI)
        let mm = sizeInMillimeters(for: pixelSize, hiDPI: hiDPI)
        return VirtualDisplayHostProtocol.Request(
            width: backing.width, height: backing.height, hiDPI: hiDPI, name: name,
            vendorID: vendorID, productID: identity.productID, serialNumber: identity.serialNumber,
            millimetersWidth: Int(mm.width), millimetersHeight: Int(mm.height))
    }

    /// The helper executable this controller will launch.
    /// - Throws: `DisplayError.helperMissing` when no executable helper can be found.
    public func helperURL() throws -> URL {
        if let explicitHelperURL {
            guard FileManager.default.isExecutableFile(atPath: explicitHelperURL.path) else {
                throw DisplayError.helperMissing
            }
            return explicitHelperURL
        }
        guard let url = VirtualDisplayHostProtocol.locateHelper() else {
            throw DisplayError.helperMissing
        }
        return url
    }

    /// Launches a helper that creates a virtual display which "looks like" `pixelSize` (backing
    /// `2 * pixelSize` when `hiDPI`), waits for it to be online, and registers it for the mirror
    /// guard.
    ///
    /// Blocks the calling thread for up to `onlineTimeout + 2` s waiting for the helper's reply.
    /// Geometry that differs from the request is recorded in `lastWarnings`, not an error.
    /// - Parameter physicalDisplayID: the display that will later mirror this one (recorded for
    ///   diagnostics; the mirror itself is set by the caller through the `DisplayService`).
    /// - Returns: the new display's UUID string.
    @discardableResult
    public func create(name: String, pixelSize: PixelSize, hiDPI: Bool, physicalDisplayID: String) throws -> String {
        let support = Self.isSupported
        guard support.0 else { throw DisplayError.virtualDisplayUnsupported(missingSymbols: support.missingSymbols) }
        let executable = try helperURL()
        let request = Self.request(name: name, pixelSize: pixelSize, hiDPI: hiDPI)

        let helper = HelperProcess(executable: executable, arguments: request.arguments)
        // Installed before launch so an exit at any later point reaches `forget`; the uuid is
        // published to the callback only once the entry exists.
        let registeredUUID = Mutex<String?>(nil)
        helper.onUnexpectedExit = { [weak self, weak helper] status in
            guard let self, let helper, let uuid = registeredUUID.withLock({ $0 }) else { return }
            self.forget(uuid, helper: helper, reason: "exited on its own with status \(status)")
        }
        do {
            try helper.launch()
        } catch {
            throw DisplayError.virtualDisplayCreationFailed("could not launch \(executable.path): \(error.localizedDescription)")
        }

        let replyTimeout = onlineTimeout + 2
        guard let line = helper.readFirstLine(timeout: replyTimeout) else {
            helper.stop(gracePeriod: Self.helperExitGracePeriod)
            throw DisplayError.virtualDisplayTimedOut(seconds: replyTimeout)
        }
        let published: VirtualDisplayHostProtocol.Published
        do {
            switch try VirtualDisplayHostProtocol.Reply.decode(line: line) {
            case .published(let p): published = p
            case .failed(let message):
                helper.stop(gracePeriod: Self.helperExitGracePeriod)
                throw DisplayError.virtualDisplayCreationFailed(message)
            }
        } catch let error as VirtualDisplayHostProtocol.CodecError {
            helper.stop(gracePeriod: Self.helperExitGracePeriod)
            throw DisplayError.virtualDisplayCreationFailed(error.localizedDescription)
        }

        // This process's online list can lag behind the helper's (docs/RESEARCH.md addendum);
        // an empty transaction refreshes it. The transaction is synchronous and the list needs no
        // run loop, so this polls with plain sleeps for a 1 s grace. A miss after that is a
        // warning, not a failure.
        let cgID = published.displayID
        let uuid = published.uuid
        var online = service.onlineDisplayIDs().contains(uuid)
        if !online {
            service.refreshDisplayList()
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                if service.onlineDisplayIDs().contains(uuid) { online = true; break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        var warnings: [String] = []
        if !online {
            warnings.append("Virtual display \(uuid) (id \(cgID)) is online per the helper but not yet listed by this process.")
        }
        if published.pointSize != pixelSize {
            warnings.append("Virtual display \(uuid) is \(published.pointSize) points; expected \(pixelSize). Physical \(physicalDisplayID) will mirror that size.")
        }
        if hiDPI, published.pixelSize != Self.backingSize(for: pixelSize, hiDPI: true) {
            warnings.append("Virtual display \(uuid) has \(published.pixelSize) backing pixels; expected \(Self.backingSize(for: pixelSize, hiDPI: true)) for HiDPI.")
        }

        registry.register(uuid, cgID: cgID)
        state.withLock { s in
            s.entries[uuid] = Entry(helper: helper, cgID: cgID, uuid: uuid)
            s.warnings = warnings
        }
        registeredUUID.withLock { $0 = uuid }
        // An exit between the reply and the insert reached the callback with no uuid; catch it here.
        if !helper.isRunning {
            helper.stop(gracePeriod: Self.helperExitGracePeriod)
            forget(uuid, helper: helper, reason: "exited before the display was registered")
            throw DisplayError.virtualDisplayCreationFailed("the display helper exited immediately after publishing \(uuid)")
        }
        return uuid
    }

    /// Dissolves any mirror that targets the virtual display, then ends its helper (see
    /// `HelperProcess.stop`). Returns without waiting for CoreGraphics to drop the display, which
    /// happens asynchronously a moment after the helper exits. Safe to call for unknown ids and
    /// from quit/sleep paths.
    public func destroy(displayID: String) {
        guard let entry = state.withLock({ $0.entries.removeValue(forKey: displayID) }) else { return }
        unmirrorEverything(mirroring: displayID)
        entry.helper.stop(gracePeriod: Self.helperExitGracePeriod)
        registry.unregister(displayID)
        // CoreGraphics drops the display a moment after the helper exits, but this process's
        // list may not notice until its next configuration transaction; run an empty one then.
        let service = self.service
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            service.refreshDisplayList()
        }
    }

    /// Destroys every virtual display this controller owns.
    public func destroyAll() {
        for id in activeDisplayIDs { destroy(displayID: id) }
    }

    /// Drops the entry for `uuid` if it still belongs to `helper`, unregisters the display, and
    /// records a warning.
    private func forget(_ uuid: String, helper: HelperProcess, reason: String) {
        let removed = state.withLock { s -> Bool in
            guard let entry = s.entries[uuid], entry.helper === helper else { return false }
            s.entries.removeValue(forKey: uuid)
            s.warnings.append("Helper for \(uuid) \(reason).")
            return true
        }
        guard removed else { return }
        registry.unregister(uuid)
        displayLog.error("helper for virtual display \(uuid, privacy: .public) \(reason, privacy: .public)")
    }

    private func unmirrorEverything(mirroring master: String) {
        for id in service.onlineDisplayIDs() where service.mirrorMaster(of: id) == master {
            do {
                try service.removeMirror(physicalDisplayID: id)
            } catch {
                displayLog.error("removeMirror(\(id, privacy: .public)) during destroy failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// One launched `forceres-vdhost` process with its pipes. `Process` and `Pipe` are not
/// `Sendable`, so each piece of shared state carries its own lock: `firstLine` holds the helper's
/// first line of stdout, written once by the background reader; `stopping` makes `stop` idempotent
/// and mutes the exit callback; `exitCallback` holds that callback. The `Process` is configured in
/// `init`, started once by `launch`, and afterwards only read (`isRunning`, `processIdentifier`)
/// or signalled (`stop`), which `Process` handles safely, so the wrapper is safe to share.
final class HelperProcess: @unchecked Sendable {
    /// How long `stop` waits for the helper to exit on stdin EOF before sending SIGTERM.
    static let stdinCloseGracePeriod: TimeInterval = 0.3

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let firstLine = Mutex<String?>(nil)
    /// Signalled once, when the helper's first line arrives or its stdout closes without one.
    private let lineArrived = DispatchSemaphore(value: 0)
    private let exitCallback = Mutex<(@Sendable (Int32) -> Void)?>(nil)
    private let stopping = Mutex(false)

    /// Called (on an arbitrary thread) when the process exits without `stop` having been called.
    var onUnexpectedExit: (@Sendable (Int32) -> Void)? {
        get { exitCallback.withLock { $0 } }
        set { exitCallback.withLock { $0 = newValue } }
    }

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
    }

    /// The helper's process id (0 before launch).
    var processIdentifier: Int32 { process.processIdentifier }

    /// Whether the helper is still running.
    var isRunning: Bool { process.isRunning }

    /// Starts the process and begins collecting its stdout.
    func launch() throws {
        process.terminationHandler = { [weak self] proc in
            guard let self, !stopping.withLock({ $0 }) else { return }
            onUnexpectedExit?(proc.terminationStatus)
        }
        try process.run()
        readFirstLineInBackground(from: stdoutPipe.fileHandleForReading.fileDescriptor)
    }

    /// Collects stdout until the first newline, then signals. Closing stdout without a line (the
    /// helper died) signals too, so `readFirstLine` never waits out its timeout for a dead helper.
    private func readFirstLineInBackground(from fd: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var line = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 4096)
            loop: while true {
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { break }
                for byte in chunk[0..<count] {
                    guard byte != UInt8(ascii: "\n") else { break loop }
                    line.append(byte)
                }
            }
            guard let self else { return }
            firstLine.withLock { $0 = line.isEmpty ? nil : String(decoding: line, as: UTF8.self) }
            lineArrived.signal()
        }
    }

    /// Waits up to `timeout` for the helper's first line of stdout. Returns nil on timeout, or if
    /// the helper closed stdout without printing one.
    func readFirstLine(timeout: TimeInterval) -> String? {
        _ = lineArrived.wait(timeout: .now() + timeout)
        return firstLine.withLock { $0 }
    }

    /// Ends the helper: closes its stdin (the primary stop signal) and waits
    /// `stdinCloseGracePeriod` for a clean exit; then SIGTERM and up to `gracePeriod` more; then
    /// SIGKILL, waiting up to one second for the kernel to reap it. Idempotent; a second call
    /// returns at once.
    func stop(gracePeriod: TimeInterval) {
        let alreadyStopping = stopping.withLock { was -> Bool in
            defer { was = true }
            return was
        }
        guard !alreadyStopping else { return }
        try? stdinPipe.fileHandleForWriting.close()
        // Closing the read end too releases the background reader if the helper never wrote a
        // line and never exited; otherwise its blocking read would hold a queue thread.
        defer { try? stdoutPipe.fileHandleForReading.close() }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if waitForExit(within: Self.stdinCloseGracePeriod) { return }
        kill(pid, SIGTERM)
        if waitForExit(within: gracePeriod) { return }
        kill(pid, SIGKILL)
        _ = waitForExit(within: 1)
    }

    /// Polls `isRunning` until it turns false or `seconds` elapse.
    private func waitForExit(within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }
}
