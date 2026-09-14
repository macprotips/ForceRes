import Foundation
import ForceResCore

/// How long a mode change should outlive the calling process.
public enum ModePersistence: String, Sendable, Codable, CaseIterable {
    /// `kCGConfigurePermanently`: macOS records the mode in its display preferences.
    case permanent
    /// `kCGConfigureForSession`: reverts at logout. Always used while any mirror set is active.
    case session
}

/// One coalesced display-reconfiguration event from `DisplayService.reconfigurations()`.
public enum DisplayReconfiguration: Sendable, Equatable {
    /// CoreGraphics is about to change display configuration (first begin-flag callback of a burst).
    case began
    /// The burst settled. `displayIDs` are the UUIDs that were reported (may be empty if a display
    /// vanished before its UUID could be read); `flags` is the union of `CGDisplayChangeSummaryFlags`.
    case ended(displayIDs: [String], flags: UInt32)
}

/// Read and change the state of connected displays. The CoreGraphics implementation is
/// `CoreGraphicsDisplayService`; `MockDisplayService` serves fixtures for tests.
///
/// Display identity is always the `CGDisplayCreateUUIDFromDisplayID` string, never a
/// `CGDirectDisplayID` (which changes across reconnects).
public protocol DisplayService: Sendable {
    /// Forces this process's view of the display list to refresh. See
    /// `CoreGraphicsDisplayService.refreshDisplayList`; the mock does nothing.
    func refreshDisplayList()

    /// Every online display with its complete mode list (duplicate low-resolution modes included).
    func snapshot() throws -> [DisplayInfo]

    /// UUIDs of every online display, in CoreGraphics order. Cheaper than `snapshot()`.
    func onlineDisplayIDs() -> [String]

    /// All modes of one display, duplicates included, in CoreGraphics order.
    func modes(for displayID: String) throws -> [DisplayModeInfo]

    /// The `ioDisplayModeID` of the display's current mode, or nil if CoreGraphics has none.
    func currentModeID(for displayID: String) throws -> Int32?

    /// Switches `displayID` to the mode whose `ioDisplayModeID == modeID`.
    ///
    /// Modes without the IOKit safe flag throw `DisplayError.unsafeMode`. If any display is in a
    /// mirror set the change is committed for the session even when `.permanent` was requested (a
    /// permanent commit would bake the mirror into the system display preferences).
    /// - Returns: the persistence that actually took effect.
    @discardableResult
    func apply(modeID: Int32, to displayID: String, persistence: ModePersistence) throws -> ModePersistence

    /// Makes the physical display a hardware mirror of a ForceRes virtual display (session scope).
    /// The master must be registered as one of ours and the mirror must not be virtual; anything
    /// else throws `DisplayError.unsafeMirrorDirection` (or `.notAPhysicalDisplay` when the target
    /// is not backed by hardware) because it crashes WindowServer.
    func setMirror(physicalDisplayID: String, ofVirtualMasterID: String) throws

    /// Removes `physicalDisplayID` from whatever mirror set it is in (session scope). No-op when
    /// the display is not mirroring.
    func removeMirror(physicalDisplayID: String) throws

    /// UUID of the display that `displayID` currently mirrors, or nil when it is not a mirror.
    func mirrorMaster(of displayID: String) -> String?

    /// Coalesced reconfiguration events. Terminating the stream unregisters the callback.
    func reconfigurations() -> AsyncStream<DisplayReconfiguration>
}

extension DisplayService {
    /// Applies the mode with `.permanent` persistence and falls back to `.session` if that fails.
    /// - Returns: the persistence that actually took effect (`.session` also when a mirror set
    ///   forced the downgrade).
    @discardableResult
    public func applyPreferringPermanent(modeID: Int32, to displayID: String) throws -> ModePersistence {
        do {
            return try apply(modeID: modeID, to: displayID, persistence: .permanent)
        } catch let permanentError as DisplayError {
            guard case .configurationFailed = permanentError else { throw permanentError }
            return try apply(modeID: modeID, to: displayID, persistence: .session)
        }
    }
}

extension DisplayService {
    public func refreshDisplayList() {}
}
