import CoreGraphics
import Foundation
import Synchronization

/// Bridges `CGDisplayRegisterReconfigurationCallback` into an `AsyncStream`, coalescing the burst
/// of per-display callbacks CoreGraphics emits for one change into a single `.ended` event.
///
/// The callback is delivered on the thread that registered it whenever its run loop spins; the
/// app (main actor) and any thread with a running `RunLoop`/`CFRunLoop` satisfy that.
///
/// `CoreGraphicsDisplayService.refreshDisplayList()` (an empty transaction) fires no callbacks
/// (measured with `forceres-dev virtual --observe --refresh`), so nothing here filters it out.
final class DisplayReconfigurationObserver: Sendable {
    private struct State {
        var continuation: AsyncStream<DisplayReconfiguration>.Continuation?
        var pendingIDs: [String] = []
        var pendingFlags: UInt32 = 0
        var burstOpen = false
        /// Incremented on every callback; a scheduled flush only fires if it still holds the latest.
        var generation: UInt64 = 0
    }

    private let state: Mutex<State>
    private let debounce: DispatchTimeInterval
    private let queue = DispatchQueue(label: "ForceRes.DisplayReconfiguration")
    /// Schedules a flush after `debounce`. Real callers get the default `DispatchQueue.asyncAfter`
    /// behaviour; tests can inject a synchronous recorder to drive the generation-counter debounce
    /// logic deterministically, without depending on wall-clock timing or `Task.sleep`.
    private let scheduleFlush: @Sendable (@escaping @Sendable () -> Void) -> Void

    /// Tests build an observer directly and feed `handle` without registering with CoreGraphics.
    init(continuation: AsyncStream<DisplayReconfiguration>.Continuation,
         debounce: DispatchTimeInterval,
         scheduleFlush: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil) {
        self.state = Mutex(State(continuation: continuation))
        self.debounce = debounce
        if let scheduleFlush {
            self.scheduleFlush = scheduleFlush
        } else {
            let queue = self.queue
            let debounce = debounce
            self.scheduleFlush = { block in
                queue.asyncAfter(deadline: .now() + debounce, execute: block)
            }
        }
    }

    /// Creates the stream and registers the CoreGraphics callback; unregisters when the consumer
    /// stops iterating or the stream is cancelled.
    static func stream(debounce: DispatchTimeInterval) -> AsyncStream<DisplayReconfiguration> {
        AsyncStream { continuation in
            let observer = DisplayReconfigurationObserver(continuation: continuation, debounce: debounce)
            let retained = Unmanaged.passRetained(observer)
            let registered = CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, retained.toOpaque())
            guard registered == .success else {
                retained.release()
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in
                CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, retained.toOpaque())
                retained.takeRetainedValue().close()
            }
        }
    }

    private func close() {
        state.withLock { s in
            s.generation &+= 1
            s.continuation = nil
        }
    }

    /// One raw CoreGraphics callback. Internal so tests can drive the debounce.
    func handle(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        if flags.contains(.beginConfigurationFlag) {
            let shouldYieldBegan: Bool = state.withLock { s in
                let first = !s.burstOpen
                s.burstOpen = true
                s.generation &+= 1
                return first
            }
            if shouldYieldBegan { yield(.began) }
            return
        }
        let uuid = CoreGraphicsDisplayService.uuidString(for: display)
        let generation: UInt64 = state.withLock { s in
            s.burstOpen = true
            if let uuid, !s.pendingIDs.contains(uuid) { s.pendingIDs.append(uuid) }
            s.pendingFlags |= flags.rawValue
            s.generation &+= 1
            return s.generation
        }
        scheduleFlush { [weak self] in
            self?.flushBurst(ifGeneration: generation)
        }
    }

    private func flushBurst(ifGeneration generation: UInt64) {
        let event: DisplayReconfiguration? = state.withLock { s in
            guard s.burstOpen, s.generation == generation else { return nil }
            let event = DisplayReconfiguration.ended(displayIDs: s.pendingIDs, flags: s.pendingFlags)
            s.pendingIDs = []
            s.pendingFlags = 0
            s.burstOpen = false
            return event
        }
        if let event { yield(event) }
    }

    private func yield(_ event: DisplayReconfiguration) {
        let continuation = state.withLock { $0.continuation }
        continuation?.yield(event)
    }
}

private let reconfigurationCallback: CGDisplayReconfigurationCallBack = { display, flags, userInfo in
    guard let userInfo else { return }
    let observer = Unmanaged<DisplayReconfigurationObserver>.fromOpaque(userInfo).takeUnretainedValue()
    observer.handle(display: display, flags: flags)
}
