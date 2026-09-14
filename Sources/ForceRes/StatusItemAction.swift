import AppKit

/// What a click on the menu bar icon does: a plain left click toggles the panel; a right click
/// or Control-click pops the settings menu (so Quit is reachable without the panel).
enum StatusItemAction: Equatable, Sendable {
    case togglePanel
    case contextMenu

    /// Routes the status button's action from the event that triggered it. `nil` (no current
    /// event, as from a debug hook) counts as a plain left click.
    static func forEvent(type: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> StatusItemAction {
        if type == .rightMouseUp || type == .rightMouseDown { return .contextMenu }
        if modifiers.contains(.control) { return .contextMenu }
        return .togglePanel
    }
}
