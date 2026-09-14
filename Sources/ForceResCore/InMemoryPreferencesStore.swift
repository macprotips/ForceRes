import Foundation
import Synchronization

/// A `PreferencesStore` that keeps everything in memory. Used by tests and previews.
public final class InMemoryPreferencesStore: PreferencesStore {
    private struct State {
        var choices: [String: DisplayChoice] = [:]
        var scaling: ScalingPreference = .hiDPI
        var originalModeIDs: [String: Int32] = [:]
        var aspects: [String: AspectRatio] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public func choice(forDisplayID displayID: String) -> DisplayChoice? {
        state.withLock { $0.choices[displayID] }
    }

    public func setChoice(_ choice: DisplayChoice, forDisplayID displayID: String) {
        state.withLock { $0.choices[displayID] = choice }
    }

    public func removeChoice(forDisplayID displayID: String) {
        state.withLock { $0.choices[displayID] = nil }
    }

    public var allChoices: [String: DisplayChoice] {
        state.withLock { $0.choices }
    }

    public var scalingPreference: ScalingPreference {
        get { state.withLock { $0.scaling } }
        set { state.withLock { $0.scaling = newValue } }
    }

    public func originalModeID(forDisplayID displayID: String) -> Int32? {
        state.withLock { $0.originalModeIDs[displayID] }
    }

    public func setOriginalModeID(_ modeID: Int32?, forDisplayID displayID: String) {
        state.withLock { $0.originalModeIDs[displayID] = modeID }
    }

    public func aspect(forDisplayID displayID: String) -> AspectRatio? {
        state.withLock { $0.aspects[displayID] }
    }

    public func setAspect(_ aspect: AspectRatio?, forDisplayID displayID: String) {
        state.withLock { $0.aspects[displayID] = aspect }
    }
}
