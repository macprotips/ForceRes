// forceres-vdhost: owns exactly one CGVirtualDisplay for the lifetime of the process. The app
// destroys the display by ending this process; VirtualDisplayController documents why.
//
// Protocol: see VirtualDisplayHostProtocol in ForceResDisplay. One JSON line on stdout, then the
// process waits until stdin reaches EOF, SIGTERM/SIGINT arrives, or the parent process exits.
import CoreGraphics
import Darwin
import Foundation
import ForceResDisplay
import VirtualDisplayBridge
import os

let log = Logger(subsystem: "com.macprotips.forceres", category: "vdhost")

// A supervisor that is already gone must not kill the helper with SIGPIPE before it can clean up.
signal(SIGPIPE, SIG_IGN)

/// Writes a reply line to stdout. A closed pipe (EPIPE) is not fatal: the supervisor is gone.
func emit(_ reply: VirtualDisplayHostProtocol.Reply) {
    try? FileHandle.standardOutput.write(contentsOf: Data(reply.line.utf8))
}

/// Reports a failure before publication (`{"error":…}`, exit 1).
func failBeforePublishing(_ message: String) -> Never {
    log.error("\(message, privacy: .public)")
    emit(.failed(message))
    exit(VirtualDisplayHostProtocol.failureExitStatus)
}

// MARK: Arguments

let request: VirtualDisplayHostProtocol.Request
do {
    request = try VirtualDisplayHostProtocol.Request.parse(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    let text = "forceres-vdhost: \(error.localizedDescription)\n\(VirtualDisplayHostProtocol.usage)\n"
    FileHandle.standardError.write(Data(text.utf8))
    exit(VirtualDisplayHostProtocol.usageExitStatus)
}

// MARK: Create the display

// Never call CGDisplayCopyAllDisplayModes (directly or via DisplayService.snapshot) before this
// point: enumerating before creation poisons this process's per-display mode cache.
let support = VirtualDisplayController.isSupported
guard support.0 else {
    failBeforePublishing("virtual displays unsupported: missing \(support.missingSymbols.joined(separator: ", "))")
}

let bridge: FRVirtualDisplayBridge
do {
    let extraModes = request.looksLikeSize.map { [NSValue(size: NSSize(width: $0.width, height: $0.height))] }
    bridge = try FRVirtualDisplayBridge(
        name: request.name,
        vendorID: request.vendorID,
        productID: request.productID,
        serialNumber: request.serialNumber,
        pixelWidth: UInt32(clamping: request.width),
        pixelHeight: UInt32(clamping: request.height),
        additionalModeSizes: extraModes,
        hiDPI: request.hiDPI,
        refreshRate: 60,
        sizeInMillimeters: CGSize(width: request.millimetersWidth, height: request.millimetersHeight))
} catch {
    failBeforePublishing("could not create the virtual display: \(error.localizedDescription)")
}

let displayID = bridge.displayID
log.info("created display \(displayID) \(request.width)x\(request.height) hiDPI=\(request.hiDPI); waiting for it to come online")

let onlineDeadline = Date().addingTimeInterval(3)
var online = false
while Date() < onlineDeadline {
    if CoreGraphicsDisplayService.onlineDisplayIDs().contains(displayID) { online = true; break }
    Thread.sleep(forTimeInterval: 0.02)
}
guard online else {
    bridge.terminate()
    failBeforePublishing("display \(displayID) did not come online within 3 s")
}
guard let uuid = CoreGraphicsDisplayService.uuidString(for: displayID) else {
    bridge.terminate()
    failBeforePublishing("CoreGraphics has no UUID for display \(displayID)")
}

let bounds = CGDisplayBounds(displayID)
// CGDisplayPixelsWide/High report points on HiDPI displays (measured), so take the backing size
// from the current mode. This process created the display before enumerating anything, so the
// mode is visible here even though it never will be in the supervisor.
let currentMode = CGDisplayCopyDisplayMode(displayID)
let published = VirtualDisplayHostProtocol.Published(
    displayID: displayID, uuid: uuid,
    pointsWidth: Int(bounds.width), pointsHeight: Int(bounds.height),
    pixelsWidth: currentMode?.pixelWidth ?? CGDisplayPixelsWide(displayID),
    pixelsHeight: currentMode?.pixelHeight ?? CGDisplayPixelsHigh(displayID))
emit(.published(published))
log.info("published \(uuid, privacy: .public): \(published.pointsWidth)x\(published.pointsHeight) pt, \(published.pixelsWidth)x\(published.pixelsHeight) px")

// MARK: Stay alive until told otherwise

/// Serializes every shutdown trigger on one queue so the bridge is released exactly once.
/// `@unchecked`: `sources` is written only by `arm()`, once, before any handler can run, and is
/// only there to keep the dispatch sources alive.
final class HostLifetime: @unchecked Sendable {
    private let bridge: FRVirtualDisplayBridge
    private let queue = DispatchQueue(label: "com.macprotips.forceres.vdhost.lifetime")
    private var sources: [any DispatchSourceProtocol] = []

    init(bridge: FRVirtualDisplayBridge) { self.bridge = bridge }

    /// Releases the display and exits. Runs on `queue`; `exit` never returns, so a second trigger
    /// queued behind the first never runs.
    private func shutdown(reason: String) {
        log.info("shutting down: \(reason, privacy: .public)")
        bridge.terminate()
        exit(0)
    }

    private func keep(_ source: any DispatchSourceProtocol) {
        sources.append(source)
        source.resume()
    }

    /// Installs every trigger: stdin EOF, SIGTERM/SIGINT, and parent exit (kqueue). The parent
    /// is re-checked once after the kqueue source is armed to close the race with an exit that
    /// happened before arming.
    func arm() {
        let stdinSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        stdinSource.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count == 0 { shutdown(reason: "stdin reached EOF") }
            else if count < 0, errno != EAGAIN, errno != EINTR { shutdown(reason: "stdin read failed (errno \(errno))") }
            // Any bytes the parent writes are ignored: stdin is only a liveness channel.
        }
        keep(stdinSource)

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [self] in shutdown(reason: "signal \(sig)") }
            keep(source)
        }

        let parent = getppid()
        if parent > 1 {
            let parentSource = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: queue)
            parentSource.setEventHandler { [self] in shutdown(reason: "parent \(parent) exited") }
            keep(parentSource)
        }
        queue.async { [self] in
            if getppid() <= 1 { shutdown(reason: "orphaned before the parent watch was armed") }
        }
    }
}

let lifetime = HostLifetime(bridge: bridge)
lifetime.arm()
dispatchMain()
