import CoreGraphics
import Foundation
import Synchronization

/// Thread-safe map of the virtual displays `VirtualDisplayController` created in this process,
/// UUID string → the `CGDirectDisplayID` the helper reported.
///
/// `CoreGraphicsDisplayService` consults it before every mirror request so that only our own
/// virtual displays can ever be a mirror master, and never a mirror target. It also serves as the
/// UUID → id map for those displays: after this process has changed display configuration itself,
/// its `CGGetOnlineDisplayList` and `CGDisplayGetDisplayIDFromUUID` can lag behind for seconds
/// (docs/RESEARCH.md addendum), while the helper has already seen the display online. Ownership
/// and teardown rules are documented on `VirtualDisplayController`.
public final class VirtualDisplayRegistry: Sendable {
    private let ids = Mutex<[String: CGDirectDisplayID]>([:])

    public init() {}

    /// Records `displayID` as a virtual display owned by this process. `cgID` may be zero when
    /// unknown (tests); real callers always pass the id the helper reported.
    public func register(_ displayID: String, cgID: CGDirectDisplayID = kCGNullDirectDisplay) {
        ids.withLock { $0[displayID] = cgID }
    }

    /// Forgets `displayID`.
    public func unregister(_ displayID: String) {
        ids.withLock { _ = $0.removeValue(forKey: displayID) }
    }

    /// Whether `displayID` is one of our virtual displays.
    public func contains(_ displayID: String) -> Bool {
        ids.withLock { $0[displayID] != nil }
    }

    /// The `CGDirectDisplayID` recorded for `displayID`, if it is ours and known.
    public func cgID(for displayID: String) -> CGDirectDisplayID? {
        ids.withLock { $0[displayID].flatMap { $0 == kCGNullDirectDisplay ? nil : $0 } }
    }

    /// The UUID registered with `cgID`, if any.
    public func displayID(for cgID: CGDirectDisplayID) -> String? {
        guard cgID != kCGNullDirectDisplay else { return nil }
        return ids.withLock { $0.first { $0.value == cgID }?.key }
    }

    /// Every registered UUID, sorted.
    public var all: [String] {
        ids.withLock { $0.keys.sorted() }
    }
}
