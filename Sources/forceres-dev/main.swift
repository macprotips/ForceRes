// forceres-dev: internal qualification tool. Never shipped. Every mutating command reverts
// automatically after a hold time unless --keep is passed, so a bad mode cannot strand the user.
//
//   forceres-dev list
//   forceres-dev apply <displayUUID|main> <modeID> [--hold 8] [--keep] [--permanent]
//   forceres-dev virtual <WxH> [--hidpi] [--mirror <displayUUID|main>] [--hold 8] [--keep] [--pre]
//                        [--observe] [--refresh] [--apply-first <modeID>] [--unmirror-wait S]
//
// `virtual --keep` holds until SIGINT (Ctrl-C), which runs the same teardown as the timed hold.
// `--observe` prints every coalesced reconfiguration event; `--refresh` runs an empty
// configuration transaction after creation, so the two together show whether
// `refreshDisplayList()` fires reconfiguration callbacks.
//
// Virtual displays are owned by a forceres-vdhost helper next to this executable (.build/debug).
//
import CoreGraphics
import Foundation
import ForceResCore
import ForceResDisplay

let registry = VirtualDisplayRegistry()
let service = CoreGraphicsDisplayService(virtualDisplays: registry)
let controller = VirtualDisplayController(service: service, registry: registry,
                                          onlineTimeout: Double(ProcessInfo.processInfo.environment["FORCERES_ONLINE_TIMEOUT"] ?? "") ?? 3)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func resolve(_ token: String) throws -> String {
    if token == "main" {
        guard let uuid = CoreGraphicsDisplayService.uuidString(for: CGMainDisplayID()) else { fail("no main display") }
        return uuid
    }
    return token
}

func describe(_ displayID: String) {
    guard let display = (try? service.snapshot())?.first(where: { $0.id == displayID }) else {
        print("  [\(displayID)] not in snapshot"); return
    }
    let cur = display.currentMode.map { "\($0.width)x\($0.height) px \($0.pixelWidth)x\($0.pixelHeight) @\($0.refreshRate)Hz id=\($0.id)" } ?? "unknown (currentModeID=\(display.currentModeID.map(String.init) ?? "nil"))"
    let cg = try? CoreGraphicsDisplayService.directDisplayID(for: displayID)
    let bounds = cg.map { CGDisplayBounds($0) } ?? .zero
    let px = cg.map { "\(CGDisplayPixelsWide($0))x\(CGDisplayPixelsHigh($0))" } ?? "?"
    let mirrorOf = cg.map { CGDisplayMirrorsDisplay($0) } ?? 0
    print("  \(display.name) [\(displayID)] builtin=\(display.isBuiltIn) main=\(display.isMain)")
    print("    current: \(cur)")
    print("    bounds: \(Int(bounds.width))x\(Int(bounds.height)) pt at (\(Int(bounds.minX)),\(Int(bounds.minY)))  pixels: \(px)  modes: \(display.modes.count)  mirrorOf: \(mirrorOf)")
}

func hold(_ args: [String]) -> TimeInterval { Double(option("--hold", args) ?? "") ?? 8 }

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: forceres-dev list | apply | virtual") }

switch command {
case "list":
    for d in try service.snapshot() { describe(d.id) }

case "apply":
    guard args.count >= 3, let modeID = Int32(args[2]) else { fail("apply <display> <modeID>") }
    let displayID = try resolve(args[1])
    let before = try service.currentModeID(for: displayID)
    print("before:"); describe(displayID)
    let persistence: ModePersistence = args.contains("--permanent") ? .permanent : .session
    try service.apply(modeID: modeID, to: displayID, persistence: persistence)
    print("applied mode \(modeID) (\(persistence)):"); describe(displayID)
    if args.contains("--keep") { print("kept."); exit(0) }
    let seconds = hold(args)
    print("reverting in \(seconds)s …")
    Thread.sleep(forTimeInterval: seconds)
    if let before { try service.apply(modeID: before, to: displayID, persistence: persistence) }
    print("reverted:"); describe(displayID)

case "virtual":
    guard args.count >= 2 else { fail("virtual <WxH> [--hidpi] [--mirror <display>]") }
    let parts = args[1].split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else { fail("size must look like 1920x1080") }
    let size = PixelSize(width: parts[0], height: parts[1])
    let hiDPI = args.contains("--hidpi")
    let mirrorTarget = try option("--mirror", args).map(resolve)
    if args.contains("--pre") {
        // Reproduce the app's situation: modes were enumerated before the virtual display existed.
        let n = (try? service.snapshot())?.reduce(0) { $0 + $1.modes.count } ?? 0
        print("pre-enumerated \(n) modes before creation")
    }
    var observerTask: Task<Void, Never>?
    if args.contains("--observe") {
        // Mimic the app: a registered reconfiguration callback and a pumped main run loop.
        observerTask = Task { @MainActor in
            let events = service.reconfigurations()
            print("    [observe] registered")
            for await event in events { print("    [reconfig] \(event)") }
            print("    [observe] stream ended")
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    }
    let observer = observerTask
    if let firstMode = Int32(option("--apply-first", args) ?? ""), let target = mirrorTarget {
        // Reproduce the app: this process changes a mode (and reverts) before going virtual.
        let before = try service.currentModeID(for: target)
        try service.apply(modeID: firstMode, to: target, persistence: .session)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
        if let before { try service.apply(modeID: before, to: target, persistence: .session) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
        print("applied \(firstMode) and reverted before creating the virtual display")
    }
    let baseline = CoreGraphicsDisplayService.onlineDisplayIDs().count
    let previousModeOfTarget = try mirrorTarget.flatMap { try service.currentModeID(for: $0) }
    print("online displays before: \(baseline)")
    let t0 = Date()
    let uuid = try controller.create(name: "ForceRes \(size)\(hiDPI ? " HiDPI" : "")", pixelSize: size, hiDPI: hiDPI,
                                     physicalDisplayID: mirrorTarget ?? "")
    print("created \(uuid) in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s; warnings: \(controller.lastWarnings)")
    describe(uuid)
    // Modes of a virtual display are never visible from this process (docs/RESEARCH.md, addendum):
    // the helper owns the display, so only bounds/pixels are meaningful here.
    if let cg = try? CoreGraphicsDisplayService.directDisplayID(for: uuid) {
        let b = CGDisplayBounds(cg)
        print("    virtual: \(Int(b.width))x\(Int(b.height)) pt  \(CGDisplayPixelsWide(cg))x\(CGDisplayPixelsHigh(cg)) px  main=\(CGDisplayIsMain(cg) != 0)")
    }
    let teardown: @MainActor () -> Void = {
        if let target = mirrorTarget, let wait = Double(option("--unmirror-wait", args) ?? "") {
            try? service.removeMirror(physicalDisplayID: target)
            let until = Date().addingTimeInterval(wait)
            while Date() < until,
                  (try? CoreGraphicsDisplayService.directDisplayID(for: target)).map({ CGDisplayMirrorsDisplay($0) }) != kCGNullDirectDisplay {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            }
            print("unmirrored after \(String(format: "%.2f", Date().timeIntervalSince(t0)))s; settling \(wait)s")
            RunLoop.current.run(until: Date(timeIntervalSinceNow: wait))
        }
        let tDestroy = Date()
        controller.destroyAll()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, CoreGraphicsDisplayService.onlineDisplayIDs().count != baseline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        print("destroyed; online displays now: \(CoreGraphicsDisplayService.onlineDisplayIDs().count) (baseline \(baseline)) destroy took \(String(format: "%.2f", Date().timeIntervalSince(tDestroy)))s")
        if let target = mirrorTarget {
            if let prev = previousModeOfTarget, (try? service.currentModeID(for: target)) != prev {
                _ = try? service.apply(modeID: prev, to: target, persistence: .session)
                print("restored target mode \(prev)")
            }
            print("target after:"); describe(target)
        }
    }
    if args.contains("--refresh") {
        // Let the creation burst settle first so any [reconfig] line printed between the two
        // markers is attributable to the empty transaction alone.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
        let before = CoreGraphicsDisplayService.onlineDisplayIDs().count
        print("refreshDisplayList: begin")
        service.refreshDisplayList()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
        print("refreshDisplayList: end; online count \(before) -> \(CoreGraphicsDisplayService.onlineDisplayIDs().count)")
    }
    if let target = mirrorTarget {
        do {
            try service.setMirror(physicalDisplayID: target, ofVirtualMasterID: uuid)
            print("mirror set: \(target) now mirrors \(uuid)")
        } catch {
            print("MIRROR FAILED: \(error)")
        }
        describe(target)
    }
    if args.contains("--keep") {
        print("holding until Ctrl-C (SIGINT runs the teardown)")
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            MainActor.assumeIsolated {
                teardown()
                observer?.cancel()
                exit(0)
            }
        }
        sigint.resume()
        RunLoop.current.run()
    }
    let seconds = hold(args)
    print("holding \(seconds)s …")
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    teardown()
    observer?.cancel()

default:
    fail("unknown command \(command)")
}
