import ForceResCore
import ForceResDisplay
import Synchronization
@testable import ForceRes

/// Records virtual-display creation and destruction without touching CoreGraphics.
final class FakeVirtualDisplayProvider: VirtualDisplayProviding, Sendable {
    struct Created: Equatable, Sendable {
        var id: String
        var name: String
        var pixelSize: PixelSize
        var hiDPI: Bool
        var physicalDisplayID: String
    }

    private struct State {
        var created: [Created] = []
        var destroyed: [String] = []
        var alive: [String] = []
        var failure: DisplayError?
        var counter = 0
    }

    private let state = Mutex(State())

    var created: [Created] { state.withLock { $0.created } }
    var destroyed: [String] { state.withLock { $0.destroyed } }
    var activeDisplayIDs: [String] { state.withLock { $0.alive } }

    /// When set, `create` throws it.
    var failure: DisplayError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    func create(name: String, pixelSize: PixelSize, hiDPI: Bool, physicalDisplayID: String) throws -> String {
        try state.withLock { s in
            if let failure = s.failure { throw failure }
            s.counter += 1
            let id = String(format: "VIRTUAL00-0000-0000-0000-%012d", s.counter)
            s.created.append(Created(id: id, name: name, pixelSize: pixelSize, hiDPI: hiDPI,
                                     physicalDisplayID: physicalDisplayID))
            s.alive.append(id)
            return id
        }
    }

    func destroy(displayID: String) {
        state.withLock { s in
            guard let index = s.alive.firstIndex(of: displayID) else { return }
            s.alive.remove(at: index)
            s.destroyed.append(displayID)
        }
    }

    func destroyAll() {
        for id in activeDisplayIDs { destroy(displayID: id) }
    }

    /// Simulates the helper process dying on its own: the display leaves `activeDisplayIDs`
    /// without being recorded in `destroyed` (mirrors `VirtualDisplayController.onUnexpectedExit`).
    func simulateHelperExit(displayID: String) {
        state.withLock { s in s.alive.removeAll { $0 == displayID } }
    }
}
