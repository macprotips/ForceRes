import AppKit
import Foundation

/// Opt-in click tracing for diagnosing focus and menu problems that only reproduce under a real
/// mouse. Off unless `FORCERES_TRACE` names a file; writes one line per event.
enum Trace {
    private static let path = ProcessInfo.processInfo.environment["FORCERES_TRACE"]
    private static let lock = NSLock()

    static var isEnabled: Bool { path != nil }

    @MainActor
    static func log(_ event: String, window: NSWindow? = nil) {
        guard let path else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        let key = window.map { "key=\($0.isKeyWindow)" } ?? "key=-"
        let line = "\(stamp) \(event) active=\(NSApp.isActive) \(key)\n"
        lock.lock()
        defer { lock.unlock() }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}
