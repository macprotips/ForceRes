import Foundation
import Synchronization
import os

/// A `PreferencesStore` backed by `UserDefaults`.
///
/// Per-display dictionaries are JSON blobs with sorted keys under `PreferencesKeys.displayChoices`
/// and `PreferencesKeys.originalModeIDs`; the scaling toggle is its raw string under
/// `PreferencesKeys.scalingPreference`. All access is serialised by a mutex.
public final class UserDefaultsPreferencesStore: PreferencesStore {
    private static let log = Logger(subsystem: "com.macprotips.forceres", category: "store")

    /// `UserDefaults` is thread-safe but not `Sendable`; every access goes through `lock`.
    private struct DefaultsBox: @unchecked Sendable {
        let value: UserDefaults
    }

    private let box: DefaultsBox
    private let lock = Mutex(())

    /// - Parameter defaults: the suite to persist into; `.standard` for the app, a throwaway suite
    ///   for tests.
    public init(defaults: UserDefaults = .standard) {
        self.box = DefaultsBox(value: defaults)
    }

    public func choice(forDisplayID displayID: String) -> DisplayChoice? {
        lock.withLock { _ in Self.loadChoices(from: box.value)[displayID] }
    }

    public func setChoice(_ choice: DisplayChoice, forDisplayID displayID: String) {
        lock.withLock { _ in
            let defaults = box.value
            var choices = Self.loadChoices(from: defaults)
            choices[displayID] = choice
            Self.saveChoices(choices, to: defaults)
        }
    }

    public func removeChoice(forDisplayID displayID: String) {
        lock.withLock { _ in
            let defaults = box.value
            var choices = Self.loadChoices(from: defaults)
            guard choices.removeValue(forKey: displayID) != nil else { return }
            Self.saveChoices(choices, to: defaults)
        }
    }

    public var allChoices: [String: DisplayChoice] {
        lock.withLock { _ in Self.loadChoices(from: box.value) }
    }

    public var scalingPreference: ScalingPreference {
        get {
            lock.withLock { _ in
                guard let raw = box.value.string(forKey: PreferencesKeys.scalingPreference) else { return .hiDPI }
                return ScalingPreference(rawValue: raw) ?? .hiDPI
            }
        }
        set {
            lock.withLock { _ in
                box.value.set(newValue.rawValue, forKey: PreferencesKeys.scalingPreference)
            }
        }
    }

    public func originalModeID(forDisplayID displayID: String) -> Int32? {
        lock.withLock { _ in Self.loadOriginalModeIDs(from: box.value)[displayID] }
    }

    public func setOriginalModeID(_ modeID: Int32?, forDisplayID displayID: String) {
        lock.withLock { _ in
            let defaults = box.value
            var ids = Self.loadOriginalModeIDs(from: defaults)
            guard ids[displayID] != modeID else { return }
            ids[displayID] = modeID
            Self.saveOriginalModeIDs(ids, to: defaults)
        }
    }

    // MARK: Encoding

    /// Encoder used for the choices blob. Sorted keys keep the stored bytes stable.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func loadChoices(from defaults: UserDefaults) -> [String: DisplayChoice] {
        loadDictionary(DisplayChoice.self, key: PreferencesKeys.displayChoices, from: defaults)
    }

    /// Decodes a `[String: Value]` blob entry by entry, so one malformed entry drops only itself.
    static func loadDictionary<Value: Decodable>(_: Value.Type, key: String,
                                                  from defaults: UserDefaults) -> [String: Value] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        let decoder = JSONDecoder()
        guard let raw = try? decoder.decode([String: LenientValue<Value>].self, from: data) else {
            log.error("Preferences blob \(key) is not a JSON dictionary; ignoring it")
            return [:]
        }
        var result: [String: Value] = [:]
        for (displayID, entry) in raw {
            if let value = entry.value {
                result[displayID] = value
            } else {
                log.error("Dropping malformed \(key) entry for display \(displayID)")
            }
        }
        return result
    }

    /// Decodes to `nil` instead of failing the enclosing container.
    private struct LenientValue<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) {
            value = try? Value(from: decoder)
        }
    }

    private static func saveChoices(_ choices: [String: DisplayChoice], to defaults: UserDefaults) {
        if choices.isEmpty {
            defaults.removeObject(forKey: PreferencesKeys.displayChoices)
            return
        }
        guard let data = try? makeEncoder().encode(choices) else { return }
        defaults.set(data, forKey: PreferencesKeys.displayChoices)
    }

    public func aspect(forDisplayID displayID: String) -> AspectRatio? {
        lock.withLock { _ in Self.loadAspects(from: box.value)[displayID] }
    }

    public func setAspect(_ aspect: AspectRatio?, forDisplayID displayID: String) {
        lock.withLock { _ in
            let defaults = box.value
            var aspects = Self.loadAspects(from: defaults)
            guard aspects[displayID] != aspect else { return }
            aspects[displayID] = aspect
            Self.save(aspects, key: PreferencesKeys.aspectRatios, to: defaults)
        }
    }

    private static func loadAspects(from defaults: UserDefaults) -> [String: AspectRatio] {
        loadDictionary(AspectRatio.self, key: PreferencesKeys.aspectRatios, from: defaults)
    }

    private static func save<Value: Encodable>(_ values: [String: Value], key: String,
                                               to defaults: UserDefaults) {
        if values.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? makeEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadOriginalModeIDs(from defaults: UserDefaults) -> [String: Int32] {
        loadDictionary(Int32.self, key: PreferencesKeys.originalModeIDs, from: defaults)
    }

    private static func saveOriginalModeIDs(_ ids: [String: Int32], to defaults: UserDefaults) {
        save(ids, key: PreferencesKeys.originalModeIDs, to: defaults)
    }
}
