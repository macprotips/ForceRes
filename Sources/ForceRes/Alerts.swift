import AppKit

/// The one modal alert the app shows (errors, About): titled "ForceRes", a single OK button, and
/// the accessory app activated for its duration so the alert comes to the front.
@MainActor
enum Alerts {
    static func runModal(_ message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = "ForceRes"
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
        NSApp.deactivate()
    }
}
