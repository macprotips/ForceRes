import os

/// Unified-logging handles shared by the app layer. Subsystem matches the bundle identifier so
/// `log stream --predicate 'subsystem == "com.macprotips.forceres"'` shows everything.
enum Log {
    static let subsystem = "com.macprotips.forceres"

    /// App lifecycle: launch, termination, signals.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Mode changes, confirmation, revert, reconcile.
    static let display = Logger(subsystem: subsystem, category: "display")
    /// Virtual display creation, mirroring, teardown.
    static let virtual = Logger(subsystem: subsystem, category: "virtual")
    /// Menu, panel, alerts.
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
