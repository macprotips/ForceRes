import Foundation
import ForceResCore
import Synchronization

/// A `DisplayService` that serves a fixed snapshot and records every mutation, for app tests.
/// Lives in the module (not the test target) so the app target can inject it.
public final class MockDisplayService: DisplayService {
    /// One recorded `apply` call. `persistence` is the effective value (see `mirrorSetActive`).
    public struct AppliedMode: Sendable, Equatable {
        public var modeID: Int32
        public var displayID: String
        public var persistence: ModePersistence
    }

    /// One recorded mirror change; `masterID == nil` means the mirror was removed.
    public struct MirrorChange: Sendable, Equatable {
        public var physicalDisplayID: String
        public var masterID: String?
    }

    private struct State {
        var displays: [DisplayInfo]
        var applied: [AppliedMode] = []
        var mirrorChanges: [MirrorChange] = []
        /// Current mirror master per mirroring display.
        var mirrors: [String: String] = [:]
        var failPermanent = false
        var mirrorSetActive = false
        var failure: DisplayError?
        var eventContinuations: [AsyncStream<DisplayReconfiguration>.Continuation] = []
    }

    private let state: Mutex<State>

    /// - Parameter displays: the snapshot to serve. `apply` updates `currentModeID` in it.
    public init(displays: [DisplayInfo]) {
        state = Mutex(State(displays: displays))
    }

    /// Every recorded `apply`, oldest first.
    public var appliedModes: [AppliedMode] { state.withLock { $0.applied } }
    /// Every recorded mirror set/remove, oldest first.
    public var mirrorChanges: [MirrorChange] { state.withLock { $0.mirrorChanges } }

    /// When true, `.permanent` applies throw a configuration error so `applyPreferringPermanent`
    /// falls back to `.session`.
    public var failPermanentApplies: Bool {
        get { state.withLock { $0.failPermanent } }
        set { state.withLock { $0.failPermanent = newValue } }
    }

    /// Simulates an active mirror set: like the CoreGraphics service, `apply` then downgrades
    /// `.permanent` requests to `.session` and reports the downgrade.
    public var mirrorSetActive: Bool {
        get { state.withLock { $0.mirrorSetActive } }
        set { state.withLock { $0.mirrorSetActive = newValue } }
    }

    /// When set, every mutating call throws this error.
    public var failure: DisplayError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    /// Replaces the served snapshot (simulating a reconnect) and emits `.ended` to observers.
    public func replaceDisplays(_ displays: [DisplayInfo]) {
        let continuations = state.withLock { s in
            s.displays = displays
            return s.eventContinuations
        }
        let event = DisplayReconfiguration.ended(displayIDs: displays.map(\.id), flags: 0)
        continuations.forEach { $0.yield(event) }
    }

    public func snapshot() throws -> [DisplayInfo] { state.withLock { $0.displays } }

    public func onlineDisplayIDs() -> [String] { state.withLock { $0.displays.map(\.id) } }

    public func modes(for displayID: String) throws -> [DisplayModeInfo] {
        try display(displayID).modes
    }

    public func currentModeID(for displayID: String) throws -> Int32? {
        try display(displayID).currentModeID
    }

    @discardableResult
    public func apply(modeID: Int32, to displayID: String, persistence: ModePersistence) throws -> ModePersistence {
        try state.withLock { s in
            if let failure = s.failure { throw failure }
            guard let index = s.displays.firstIndex(where: { $0.id == displayID }) else {
                throw DisplayError.displayNotFound(displayID)
            }
            guard let mode = s.displays[index].modes.first(where: { $0.id == modeID }) else {
                throw DisplayError.modeNotFound(modeID: modeID, displayID: displayID)
            }
            guard mode.isSafe else { throw DisplayError.unsafeMode(modeID: modeID) }
            let effective: ModePersistence = s.mirrorSetActive ? .session : persistence
            if effective == .permanent, s.failPermanent {
                throw DisplayError.configurationFailed(stage: .complete, code: 1000, fullScreenAppBlocking: false)
            }
            s.displays[index].currentModeID = modeID
            s.applied.append(AppliedMode(modeID: modeID, displayID: displayID, persistence: effective))
            return effective
        }
    }

    public func setMirror(physicalDisplayID: String, ofVirtualMasterID masterID: String) throws {
        try state.withLock { s in
            if let failure = s.failure { throw failure }
            s.mirrors[physicalDisplayID] = masterID
            s.mirrorChanges.append(MirrorChange(physicalDisplayID: physicalDisplayID, masterID: masterID))
        }
    }

    public func removeMirror(physicalDisplayID: String) throws {
        try state.withLock { s in
            if let failure = s.failure { throw failure }
            s.mirrors.removeValue(forKey: physicalDisplayID)
            s.mirrorChanges.append(MirrorChange(physicalDisplayID: physicalDisplayID, masterID: nil))
        }
    }

    public func mirrorMaster(of displayID: String) -> String? {
        state.withLock { $0.mirrors[displayID] }
    }

    public func reconfigurations() -> AsyncStream<DisplayReconfiguration> {
        AsyncStream { continuation in
            state.withLock { $0.eventContinuations.append(continuation) }
        }
    }

    private func display(_ id: String) throws -> DisplayInfo {
        guard let display = try snapshot().first(where: { $0.id == id }) else {
            throw DisplayError.displayNotFound(id)
        }
        return display
    }
}
