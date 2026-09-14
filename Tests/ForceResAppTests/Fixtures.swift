import Foundation
import ForceResCore
import ForceResDisplay
@testable import ForceRes

/// Loads the recorded `DisplaySnapshot` fixtures shared with `ForceResCoreTests`, by path
/// (this target declares no resources in Package.swift).
enum Fixtures {
    enum Fixture: String {
        /// Real dump: Mac mini (M4) driving a Samsung Odyssey G80SD, 242 modes.
        case m4OdysseyG80SD = "m4-mac-mini-odyssey-g80sd"
        /// Synthetic 16-mode M1 MacBook Air built-in panel.
        case m1MacBookAir = "m1-macbook-air-builtin"
        /// Synthetic 1080p-native external monitor with no HiDPI 1080p variant.
        case external1080p = "external-1080p-60hz"
    }

    enum Error: Swift.Error { case noDisplays(String) }

    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ForceResAppTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("ForceResCoreTests/Fixtures")
    }

    static func snapshot(_ fixture: Fixture) throws -> DisplaySnapshot {
        let url = directory.appendingPathComponent("\(fixture.rawValue).json")
        return try DisplaySnapshot.decode(from: Data(contentsOf: url))
    }

    static func display(_ fixture: Fixture) throws -> DisplayInfo {
        guard let display = try snapshot(fixture).displays.first else { throw Error.noDisplays(fixture.rawValue) }
        return display
    }
}

/// Everything a model test needs, wired together with fakes.
@MainActor
struct Harness {
    let service: MockDisplayService
    let store = InMemoryPreferencesStore()
    let provider: FakeVirtualDisplayProvider?
    let clock = TestClock()
    /// The model's wall clock; advance it to get past cooldowns.
    let nowBox = NowBox()
    var now: Date {
        get { nowBox.value }
        nonmutating set { nowBox.value = newValue }
    }
    let model: AppModel

    init(displays: [DisplayInfo], virtual: Bool = true, scaling: ScalingPreference = .hiDPI) {
        service = MockDisplayService(displays: displays)
        store.scalingPreference = scaling
        provider = virtual ? FakeVirtualDisplayProvider() : nil
        model = AppModel(service: service, store: store, virtualProvider: provider, clock: clock,
                         now: { [nowBox] in nowBox.value }, launchAtLoginAvailable: false)
        model.refresh()
    }

    var display: DisplayInfo { model.displays[0] }
}

/// Equatable mirror of `MockDisplayService.AppliedMode` (whose memberwise init is not public).
struct Applied: Equatable, Sendable {
    let modeID: Int32
    let displayID: String
    let persistence: ModePersistence
    init(_ modeID: Int32, _ displayID: String, _ persistence: ModePersistence) {
        self.modeID = modeID
        self.displayID = displayID
        self.persistence = persistence
    }
    init(_ applied: MockDisplayService.AppliedMode) {
        self.init(applied.modeID, applied.displayID, applied.persistence)
    }
}

/// Equatable mirror of `MockDisplayService.MirrorChange`; `master == nil` means removed.
struct Mirror: Equatable, Sendable {
    let physicalDisplayID: String
    let master: String?
    init(_ physicalDisplayID: String, _ master: String?) {
        self.physicalDisplayID = physicalDisplayID
        self.master = master
    }
    init(_ change: MockDisplayService.MirrorChange) {
        self.init(change.physicalDisplayID, change.masterID)
    }
}

extension MockDisplayService {
    var applied: [Applied] { appliedModes.map(Applied.init) }
    var mirrors: [Mirror] { mirrorChanges.map(Mirror.init) }
}

/// A mutable, shareable wall-clock value for the model's `now` closure.
final class NowBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Date(timeIntervalSinceReferenceDate: 0)
    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
