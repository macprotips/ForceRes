import AppKit
import CoreGraphics
import Foundation
import ForceResCore

/// The live `DisplayService`, backed by public CoreGraphics (Quartz Display Services) only.
///
/// CoreGraphics display calls are thread-safe, so this class holds no mutable state of its own;
/// the only shared state is the injected `VirtualDisplayRegistry`, which is itself locked.
public final class CoreGraphicsDisplayService: DisplayService {
    /// Registry of virtual displays created by this process; used to validate mirror direction.
    public let virtualDisplays: VirtualDisplayRegistry

    /// - Parameter virtualDisplays: share the same registry with the `VirtualDisplayController`.
    public init(virtualDisplays: VirtualDisplayRegistry = VirtualDisplayRegistry()) {
        self.virtualDisplays = virtualDisplays
    }

    /// Some Quartz entry points (`CGDisplayGetDisplayIDFromUUID` among them) assert
    /// `CGS_REQUIRE_INIT` if they are the first CoreGraphics call in the process. Touching
    /// `CGMainDisplayID` once, through a thread-safe static, initializes the connection.
    private static let initialized: Void = { _ = CGMainDisplayID() }()

    // MARK: Identity helpers (also used by the controller and tests)

    /// `CGDisplayCreateUUIDFromDisplayID` as an uppercase string, or nil if CG has no UUID for it.
    public static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        _ = initialized
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Resolves a UUID string to a `CGDirectDisplayID`, skipping the online check for virtual
    /// displays this process's helpers created: the helper already saw them online, and this
    /// process's own `CGGetOnlineDisplayList` can lag behind after it changed display
    /// configuration itself (docs/RESEARCH.md addendum).
    func resolveDisplayID(for uuidString: String) throws -> CGDirectDisplayID {
        if virtualDisplays.contains(uuidString) {
            if let cgID = virtualDisplays.cgID(for: uuidString) { return cgID }
            return try Self.directDisplayID(for: uuidString, requireOnline: false)
        }
        return try Self.directDisplayID(for: uuidString)
    }

    /// Resolves a UUID string back to the current `CGDirectDisplayID`.
    /// - Parameter requireOnline: when `true` (default) the id must appear in
    ///   `CGGetOnlineDisplayList`; otherwise any id CoreGraphics derives from the UUID is accepted.
    /// - Throws: `DisplayError.invalidDisplayUUID` or `.displayNotFound`.
    public static func directDisplayID(for uuidString: String, requireOnline: Bool = true) throws -> CGDirectDisplayID {
        // CFUUIDCreateFromString is lenient (it accepts "nope"); validate the format with Foundation first.
        guard UUID(uuidString: uuidString) != nil,
              let uuid = CFUUIDCreateFromString(nil, uuidString as CFString) else {
            throw DisplayError.invalidDisplayUUID(uuidString)
        }
        _ = initialized
        let id = CGDisplayGetDisplayIDFromUUID(uuid)
        guard id != kCGNullDirectDisplay, !requireOnline || Self.onlineDisplayIDs().contains(id) else {
            throw DisplayError.displayNotFound(uuidString)
        }
        return id
    }

    /// `CGGetOnlineDisplayList` (includes mirrored and sleeping displays).
    public static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        _ = initialized
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        let err = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        guard err == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    // MARK: Enumeration

    public func snapshot() throws -> [DisplayInfo] {
        let screenNames = Self.screenNames()
        let physical = PhysicalDisplayDetector.scan()
        var displays: [DisplayInfo] = []
        for (index, id) in Self.onlineDisplayIDs().enumerated() {
            guard let uuid = Self.uuidString(for: id) else { continue }
            let modes = Self.modeInfos(for: id)
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            let name = screenNames[id]
                ?? (isBuiltIn ? "Built-in Display" : "Display \(index + 1)")
            displays.append(DisplayInfo(
                id: uuid,
                name: name,
                isBuiltIn: isBuiltIn,
                isMain: CGDisplayIsMain(id) != 0,
                nativePixelSize: ModeSelector.nativePixelSize(from: modes),
                modes: modes,
                currentModeID: CGDisplayCopyDisplayMode(id)?.ioDisplayModeID,
                isPhysical: physical.isPhysical(id),
                variableRefreshRange: physical.variableRefreshRange(id)))
        }
        return displays
    }

    public func onlineDisplayIDs() -> [String] {
        Self.onlineDisplayIDs().compactMap(Self.uuidString(for:))
    }

    public func modes(for displayID: String) throws -> [DisplayModeInfo] {
        Self.modeInfos(for: try resolveDisplayID(for: displayID))
    }

    public func currentModeID(for displayID: String) throws -> Int32? {
        CGDisplayCopyDisplayMode(try resolveDisplayID(for: displayID))?.ioDisplayModeID
    }

    /// `NSScreen.localizedName` keyed by `CGDirectDisplayID` (via `NSScreenNumber`).
    ///
    /// `NSScreen.screens` is main-actor state (AppKit). `snapshot()` is called from the app's
    /// main thread but also from tools, tests and background queues, so the names are read on the
    /// main thread whichever thread the caller is on: `MainActor.assumeIsolated` when already
    /// there (a `DispatchQueue.main.sync` from the main thread would deadlock), otherwise a
    /// synchronous hop to the main queue. Callers on a queue that the main thread is itself
    /// waiting on would deadlock; nothing in ForceRes does that.
    private static func screenNames() -> [CGDirectDisplayID: String] {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { screenNamesOnMain() }
        }
        return DispatchQueue.main.sync { screenNamesOnMain() }
    }

    @MainActor
    private static func screenNamesOnMain() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { continue }
            let name = screen.localizedName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names[CGDirectDisplayID(number.uint32Value)] = name }
        }
        return names
    }

    /// Raw `CGDisplayMode` list with duplicate low-resolution modes, in CoreGraphics order.
    static func cgModes(for id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
    }

    /// Every mode of `id` with `isVariableRefresh`/`isProMotion` filled in by
    /// `VariableRefreshClassifier` (nil when the private symbols are unavailable).
    static func modeInfos(for id: CGDirectDisplayID) -> [DisplayModeInfo] {
        cgModes(for: id).map { VariableRefreshClassifier.classify(DisplayModeInfo(cgMode: $0), displayID: id) }
    }

    // MARK: Configuration

    @discardableResult
    public func apply(modeID: Int32, to displayID: String, persistence: ModePersistence) throws -> ModePersistence {
        let id = try resolveDisplayID(for: displayID)
        guard let mode = Self.cgModes(for: id).first(where: { $0.ioDisplayModeID == modeID }) else {
            throw DisplayError.modeNotFound(modeID: modeID, displayID: displayID)
        }
        guard mode.ioFlags & DisplayModeInfo.IOFlags.safe != 0 else {
            throw DisplayError.unsafeMode(modeID: modeID)
        }
        // Never commit permanently while any mirror set exists: it bakes the mirror
        // into the window server preferences.
        let effective: ModePersistence = Self.anyMirrorSetActive() ? .session : persistence
        try Self.transaction { config in
            let err = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
            guard err == .success else { throw DisplayError.configuration(.configure, err) }
        } commit: { config in
            CGCompleteDisplayConfiguration(config, effective == .permanent ? .permanently : .forSession)
        }
        return effective
    }

    public func setMirror(physicalDisplayID: String, ofVirtualMasterID masterID: String) throws {
        guard virtualDisplays.contains(masterID), !virtualDisplays.contains(physicalDisplayID) else {
            throw DisplayError.unsafeMirrorDirection(master: masterID, mirror: physicalDisplayID)
        }
        let mirror = try Self.directDisplayID(for: physicalDisplayID)
        let master = try resolveDisplayID(for: masterID)
        // The registry can be stale after a reconnect; a display never mirrors itself.
        guard master != mirror else {
            throw DisplayError.unsafeMirrorDirection(master: masterID, mirror: physicalDisplayID)
        }
        // The registry only knows our own virtual displays; anyone else's must be refused too.
        guard PhysicalDisplayDetector.scan().isPhysical(mirror) else {
            throw DisplayError.notAPhysicalDisplay(physicalDisplayID)
        }
        try Self.mirrorTransaction(mirror: mirror, master: master)
    }

    public func removeMirror(physicalDisplayID: String) throws {
        let mirror = try Self.directDisplayID(for: physicalDisplayID)
        guard CGDisplayMirrorsDisplay(mirror) != kCGNullDirectDisplay else { return }
        try Self.mirrorTransaction(mirror: mirror, master: kCGNullDirectDisplay)
    }

    public func mirrorMaster(of displayID: String) -> String? {
        guard let id = try? resolveDisplayID(for: displayID) else { return nil }
        let master = CGDisplayMirrorsDisplay(id)
        guard master != kCGNullDirectDisplay else { return nil }
        return virtualDisplays.displayID(for: master) ?? Self.uuidString(for: master)
    }

    /// Runs an empty configuration transaction. After this process has changed display
    /// configuration itself, CoreGraphics stops refreshing its per-process display list until the
    /// next transaction (measured, docs/RESEARCH.md addendum); an empty one forces the refresh so
    /// that a display another process created becomes visible here. The empty transaction fires
    /// no reconfiguration callbacks (measured with `forceres-dev virtual --observe --refresh`).
    public func refreshDisplayList() {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            displayLog.error("refreshDisplayList: CGBeginDisplayConfiguration failed (CGError \(begin.rawValue))")
            return
        }
        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        if complete != .success {
            displayLog.error("refreshDisplayList: CGCompleteDisplayConfiguration failed (CGError \(complete.rawValue))")
        }
    }

    /// Whether any online display is part of a mirror set.
    public static func anyMirrorSetActive() -> Bool {
        onlineDisplayIDs().contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    private static func mirrorTransaction(mirror: CGDirectDisplayID, master: CGDirectDisplayID) throws {
        try transaction { config in
            let err = CGConfigureDisplayMirrorOfDisplay(config, mirror, master)
            guard err == .success else { throw DisplayError.configuration(.mirror, err) }
        } commit: { config in
            CGCompleteDisplayConfiguration(config, .forSession)
        }
    }

    /// Runs `body` inside `CGBeginDisplayConfiguration`; cancels on throw, otherwise commits.
    private static func transaction(
        _ body: (CGDisplayConfigRef) throws -> Void,
        commit: (CGDisplayConfigRef) -> CGError
    ) throws {
        var config: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&config)
        guard beginError == .success, let config else {
            throw DisplayError.configuration(.begin, beginError == .success ? .failure : beginError)
        }
        do {
            try body(config)
        } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }
        let completeError = commit(config)
        guard completeError == .success else { throw DisplayError.configuration(.complete, completeError) }
    }

    // MARK: Reconfiguration

    public func reconfigurations() -> AsyncStream<DisplayReconfiguration> {
        DisplayReconfigurationObserver.stream(debounce: .milliseconds(300))
    }
}

extension DisplayModeInfo {
    /// Converts a live `CGDisplayMode` into the fixture-friendly value type.
    public init(cgMode m: CGDisplayMode) {
        self.init(id: m.ioDisplayModeID,
                  width: m.width,
                  height: m.height,
                  pixelWidth: m.pixelWidth,
                  pixelHeight: m.pixelHeight,
                  refreshRate: m.refreshRate,
                  ioFlags: m.ioFlags,
                  isUsableForDesktopGUI: m.isUsableForDesktopGUI())
    }
}
