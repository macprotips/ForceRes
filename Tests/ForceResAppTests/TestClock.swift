import Foundation
import Synchronization

/// A `Clock` that only moves when a test calls `advance(by:)`. Sleepers whose deadline has passed
/// are resumed in `advance`, so countdown logic can be stepped deterministically.
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// Number of tasks currently blocked in `sleep`.
    var pendingSleepers: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        // A task cancelled before it first sleeps must not register a sleeper nobody resumes.
        try Task.checkCancellation()
        let id: UInt64 = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = state.withLock { s in
                    if deadline <= s.now { return true }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { s -> Sleeper? in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline is now due.
    func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { s in
            s.now = s.now.advanced(by: duration)
            let (ready, waiting) = s.sleepers.reduce(into: ([Sleeper](), [Sleeper]())) { acc, sleeper in
                if sleeper.deadline <= s.now { acc.0.append(sleeper) } else { acc.1.append(sleeper) }
            }
            s.sleepers = waiting
            return ready.sorted { $0.deadline < $1.deadline }
        }
        due.forEach { $0.continuation.resume() }
    }
}

/// Lets main-actor tasks that were resumed by `TestClock.advance` run to their next suspension.
@MainActor
func settle(iterations: Int = 25) async {
    for _ in 0..<iterations { await Task.yield() }
}
