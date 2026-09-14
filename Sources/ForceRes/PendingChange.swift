import Foundation

/// A mode change that has been applied but not yet confirmed by the user. If neither `keep` nor
/// `revert` runs before the countdown ends, the model reverts it.
struct PendingChange {
    /// UUID of the physical display the change affects.
    let displayID: String
    /// Plain-English summary, e.g. "Odyssey G80SD → 1080p (1920 × 1080) HiDPI at 240 Hertz".
    let description: String
    /// Undoes the change. Must not persist anything. `final` is `true` when the process is
    /// terminating or the Mac is going to sleep: a virtual mirror the change replaced must then
    /// stay down rather than be recreated.
    let revert: @MainActor (_ final: Bool) throws -> Void
    /// Makes the change stick: persists the choice and, for native modes, re-applies permanently.
    let keep: @MainActor () throws -> Void
}
