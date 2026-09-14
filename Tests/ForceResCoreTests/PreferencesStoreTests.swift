import Foundation
import Testing
import ForceResCore

/// A throwaway `UserDefaults` suite whose persistent domain and plist are removed when the value
/// is dropped, so no `ForceResCoreTests.*.plist` is left in `~/Library/Preferences`
/// (`removePersistentDomain` alone leaves an empty file behind).
final class ScratchDefaults: @unchecked Sendable {
    let suite: String
    let defaults: UserDefaults

    init() throws {
        suite = "ForceResCoreTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    deinit {
        Self.wipe(suite: suite, defaults: defaults)
    }

    /// Removes the domain, forces cfprefsd to flush it, and deletes the (now empty) plist. The
    /// flush can land after the delete under load, so the delete is retried briefly.
    static func wipe(suite: String, defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suite)
        CFPreferencesAppSynchronize(suite as CFString)
        let url = plistURL(forSuite: suite)
        let deadline = Date().addingTimeInterval(1)
        repeat {
            try? FileManager.default.removeItem(at: url)
            Thread.sleep(forTimeInterval: 0.02)
        } while FileManager.default.fileExists(atPath: url.path) && Date() < deadline
    }

    static func plistURL(forSuite suite: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
    }
}

@Suite("PreferencesStore implementations")
struct PreferencesStoreTests {
    private static func stores() throws -> [(String, any PreferencesStore, ScratchDefaults?)] {
        let scratch = try ScratchDefaults()
        return [("InMemory", InMemoryPreferencesStore(), nil),
                ("UserDefaults", UserDefaultsPreferencesStore(defaults: scratch.defaults), scratch)]
    }

    @Test func choiceRoundTripAndRemoval() throws {
        for (name, store, _) in try Self.stores() {
            #expect(store.choice(forDisplayID: "A") == nil, Comment(rawValue: name))
            #expect(store.allChoices.isEmpty, Comment(rawValue: name))

            let choice = DisplayChoice(preset: .fullHD1080, scaling: .lowResolution)
            store.setChoice(choice, forDisplayID: "A")
            store.setChoice(DisplayChoice(preset: nil, scaling: .hiDPI), forDisplayID: "B")
            #expect(store.choice(forDisplayID: "A") == choice, Comment(rawValue: name))
            #expect(store.choice(forDisplayID: "B")?.preset == nil, Comment(rawValue: name))
            #expect(store.allChoices.count == 2, Comment(rawValue: name))

            store.setChoice(DisplayChoice(preset: .uhd2160, scaling: .hiDPI), forDisplayID: "A")
            #expect(store.choice(forDisplayID: "A")?.preset == .uhd2160, Comment(rawValue: name))

            store.removeChoice(forDisplayID: "A")
            store.removeChoice(forDisplayID: "never-set")
            #expect(store.choice(forDisplayID: "A") == nil, Comment(rawValue: name))
            #expect(store.allChoices == ["B": DisplayChoice(preset: nil, scaling: .hiDPI)], Comment(rawValue: name))
        }
    }

    @Test func scalingPreferenceDefaultsToHiDPIAndPersists() throws {
        for (name, store, _) in try Self.stores() {
            #expect(store.scalingPreference == .hiDPI, Comment(rawValue: name))
            store.scalingPreference = .lowResolution
            #expect(store.scalingPreference == .lowResolution, Comment(rawValue: name))
        }
    }

    @Test func userDefaultsStoreSurvivesReinstantiation() throws {
        let scratch = try ScratchDefaults()
        let defaults = scratch.defaults
        let first = UserDefaultsPreferencesStore(defaults: defaults)
        first.setChoice(DisplayChoice(preset: .qhd1440, scaling: .hiDPI), forDisplayID: "uuid-1")
        first.scalingPreference = .lowResolution
        first.setOriginalModeID(133, forDisplayID: "uuid-1")

        let second = UserDefaultsPreferencesStore(defaults: defaults)
        #expect(second.choice(forDisplayID: "uuid-1") == DisplayChoice(preset: .qhd1440, scaling: .hiDPI))
        #expect(second.scalingPreference == .lowResolution)
        #expect(second.originalModeID(forDisplayID: "uuid-1") == 133)
    }

    @Test func originalModeIDRoundTripsAndClearsIndependentlyOfChoices() throws {
        for (name, store, _) in try Self.stores() {
            #expect(store.originalModeID(forDisplayID: "A") == nil, Comment(rawValue: name))
            store.setOriginalModeID(133, forDisplayID: "A")
            store.setOriginalModeID(8, forDisplayID: "B")
            #expect(store.originalModeID(forDisplayID: "A") == 133, Comment(rawValue: name))
            #expect(store.originalModeID(forDisplayID: "B") == 8, Comment(rawValue: name))

            // Choices and originals are separate: removing one leaves the other.
            store.setChoice(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI), forDisplayID: "A")
            store.removeChoice(forDisplayID: "A")
            #expect(store.originalModeID(forDisplayID: "A") == 133, Comment(rawValue: name))

            store.setOriginalModeID(132, forDisplayID: "A")
            #expect(store.originalModeID(forDisplayID: "A") == 132, Comment(rawValue: name))
            store.setOriginalModeID(nil, forDisplayID: "A")
            store.setOriginalModeID(nil, forDisplayID: "never-set")
            #expect(store.originalModeID(forDisplayID: "A") == nil, Comment(rawValue: name))
            #expect(store.originalModeID(forDisplayID: "B") == 8, Comment(rawValue: name))
            #expect(store.allChoices.isEmpty, Comment(rawValue: name))
        }
    }

    @Test func userDefaultsOriginalModeIDsAreNamespacedJSON() throws {
        let scratch = try ScratchDefaults()
        let defaults = scratch.defaults
        let store = UserDefaultsPreferencesStore(defaults: defaults)
        #expect(PreferencesKeys.originalModeIDs.hasPrefix("ForceRes."))
        store.setOriginalModeID(133, forDisplayID: "uuid-1")
        let data = try #require(defaults.data(forKey: PreferencesKeys.originalModeIDs))
        #expect(String(decoding: data, as: UTF8.self) == #"{"uuid-1":133}"#)
        #expect(defaults.data(forKey: PreferencesKeys.displayChoices) == nil)

        store.setOriginalModeID(nil, forDisplayID: "uuid-1")
        #expect(defaults.data(forKey: PreferencesKeys.originalModeIDs) == nil)

        defaults.set(Data("not json".utf8), forKey: PreferencesKeys.originalModeIDs)
        #expect(store.originalModeID(forDisplayID: "uuid-1") == nil)
    }

    @Test func userDefaultsKeysAreNamespacedAndJSON() throws {
        let scratch = try ScratchDefaults()
        let defaults = scratch.defaults
        let store = UserDefaultsPreferencesStore(defaults: defaults)
        store.setChoice(DisplayChoice(preset: .hd720, scaling: .hiDPI), forDisplayID: "uuid-1")
        store.scalingPreference = .lowResolution

        #expect(PreferencesKeys.displayChoices.hasPrefix("ForceRes."))
        #expect(PreferencesKeys.scalingPreference.hasPrefix("ForceRes."))
        #expect(defaults.string(forKey: PreferencesKeys.scalingPreference) == "lowResolution")
        let data = try #require(defaults.data(forKey: PreferencesKeys.displayChoices))
        #expect(String(decoding: data, as: UTF8.self) == #"{"uuid-1":{"preset":"hd720","scaling":"hiDPI"}}"#)

        store.removeChoice(forDisplayID: "uuid-1")
        #expect(defaults.data(forKey: PreferencesKeys.displayChoices) == nil)
    }

    @Test func corruptChoicesBlobIsTreatedAsEmpty() throws {
        let scratch = try ScratchDefaults()
        let defaults = scratch.defaults
        defaults.set(Data("not json".utf8), forKey: PreferencesKeys.displayChoices)
        defaults.set("bogus", forKey: PreferencesKeys.scalingPreference)
        let store = UserDefaultsPreferencesStore(defaults: defaults)
        #expect(store.allChoices.isEmpty)
        #expect(store.scalingPreference == .hiDPI)
    }

    @Test func oneMalformedEntryDoesNotDropTheOthers() throws {
        let scratch = try ScratchDefaults()
        let defaults = scratch.defaults
        let choices = #"{"bad":{"preset":"8K","scaling":"hiDPI"},"good":{"preset":"hd720","scaling":"hiDPI"},"odd":7}"#
        defaults.set(Data(choices.utf8), forKey: PreferencesKeys.displayChoices)
        defaults.set(Data(#"{"a":133,"b":"x"}"#.utf8), forKey: PreferencesKeys.originalModeIDs)
        let store = UserDefaultsPreferencesStore(defaults: defaults)
        #expect(store.allChoices == ["good": DisplayChoice(preset: .hd720, scaling: .hiDPI)])
        #expect(store.originalModeID(forDisplayID: "a") == 133)
        #expect(store.originalModeID(forDisplayID: "b") == nil)
    }

    @Test func scratchSuitesLeaveNoPreferencesFileBehind() throws {
        let suite: String
        do {
            let scratch = try ScratchDefaults()
            suite = scratch.suite
            scratch.defaults.set("x", forKey: "probe")
            scratch.defaults.synchronize()
        }
        #expect(UserDefaults(suiteName: suite)?.persistentDomain(forName: suite)?.isEmpty ?? true)
        #expect(!FileManager.default.fileExists(atPath: ScratchDefaults.plistURL(forSuite: suite).path))
    }
}

@Suite("DisplayChoice JSON stability")
struct DisplayChoiceCodingTests {
    private func encode(_ choice: DisplayChoice) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(choice), as: UTF8.self)
    }

    @Test func presetChoiceEncodesRawValues() throws {
        #expect(try encode(DisplayChoice(preset: .fullHD1080, scaling: .hiDPI))
            == #"{"preset":"fullHD1080","scaling":"hiDPI"}"#)
    }

    @Test func nativeChoiceOmitsPreset() throws {
        #expect(try encode(DisplayChoice(preset: nil, scaling: .lowResolution)) == #"{"scaling":"lowResolution"}"#)
        let decoded = try JSONDecoder().decode(DisplayChoice.self, from: Data(#"{"scaling":"lowResolution"}"#.utf8))
        #expect(decoded == DisplayChoice(preset: nil, scaling: .lowResolution))
    }

    @Test func snapshotRoundTripsThroughFixtureCoding() throws {
        let snapshot = try FixtureLoader.snapshot(.external1080p)
        let data = try snapshot.encodedJSON()
        let again = try DisplaySnapshot.decode(from: data)
        #expect(again.displays == snapshot.displays)
        #expect(again.capturedAt == snapshot.capturedAt)
        #expect(again.machine == snapshot.machine)
    }
}
