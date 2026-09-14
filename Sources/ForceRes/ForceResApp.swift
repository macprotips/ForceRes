import SwiftUI

/// Menu bar only. The status item and popover are AppKit (`StatusItemController`); the inert
/// `Settings` scene is never presented. `LSUIElement` and `AppDelegate` suppress the Dock icon.
@main
struct ForceResApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
