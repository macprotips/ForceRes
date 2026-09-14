import AppKit
import SwiftUI

/// A borderless control that pops an AppKit menu: SwiftUI draws the label and the hover fill,
/// and a transparent `MenuTriggerView` on top owns the mouse, keyboard focus, accessibility and
/// the tooltip. The menu is built fresh on every open from `menu`, so the panel re-rendering
/// underneath (countdown ticks, display reconfiguration) never disturbs a menu that is tracking.
/// A SwiftUI `Menu` inside a popover that is neither key nor active collapses both when clicked.
struct PanelMenuButton<Label: View>: View {
    /// Lets VoiceOver tell the two controls apart.
    let role: NSAccessibility.Role
    let accessibilityLabel: String
    let accessibilityValue: String?
    let accessibilityHelp: String?
    let toolTip: String
    let isEnabled: Bool
    /// `FORCERES_OPEN_MENU` value that pops this control's menu (debug builds).
    let developmentName: String
    let menu: @MainActor () -> NSMenu
    @ViewBuilder let label: (_ isHovered: Bool) -> Label

    @State private var isHovered = false
    @State private var isOpen = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelMetrics.controlCornerRadius, style: .continuous)
        label(isHovered)
            .background(fill, in: shape)
            .accessibilityHidden(true)
            .overlay {
                MenuTrigger(role: role, accessibilityLabel: accessibilityLabel, accessibilityValue: accessibilityValue,
                            accessibilityHelp: accessibilityHelp, toolTip: toolTip, isEnabled: isEnabled,
                            developmentName: developmentName, menu: menu,
                            hoverChanged: { isHovered = $0 }, openChanged: { isOpen = $0 })
            }
            .fixedSize()
    }

    /// No chrome at rest, the unselected-tile fill on hover, one step darker while the menu is up.
    private var fill: Color {
        if isOpen { return Color(nsColor: .tertiarySystemFill) }
        if isHovered { return Color(nsColor: .quaternarySystemFill) }
        return .clear
    }
}

private struct MenuTrigger: NSViewRepresentable {
    let role: NSAccessibility.Role
    let accessibilityLabel: String
    let accessibilityValue: String?
    let accessibilityHelp: String?
    let toolTip: String
    let isEnabled: Bool
    let developmentName: String
    let menu: @MainActor () -> NSMenu
    let hoverChanged: (Bool) -> Void
    let openChanged: (Bool) -> Void

    func makeNSView(context: Context) -> MenuTriggerView { MenuTriggerView() }

    func updateNSView(_ view: MenuTriggerView, context: Context) {
        view.menuBuilder = menu
        view.hoverChanged = hoverChanged
        view.openChanged = openChanged
        view.isEnabled = isEnabled
        view.developmentName = developmentName
        view.toolTip = toolTip
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(role)
        view.setAccessibilityLabel(accessibilityLabel)
        view.setAccessibilityValue(accessibilityValue)
        view.setAccessibilityHelp(accessibilityHelp)
        view.setAccessibilityEnabled(isEnabled)
    }
}

/// The AppKit half of `PanelMenuButton`. Pops its menu at the control's bottom-left on
/// mouse-down, Space or Return; reports hover from a tracking area; never takes focus from a
/// click, so the focus ring appears only when Tab reaches it.
@MainActor
final class MenuTriggerView: NSView {
    var menuBuilder: (@MainActor () -> NSMenu)?
    var hoverChanged: ((Bool) -> Void)?
    var openChanged: ((Bool) -> Void)?
    var isEnabled = true {
        didSet { if !isEnabled { setHovered(false) } }
    }
    var developmentName = ""
    private var isHovered = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var needsPanelToBecomeKey: Bool { true }

    /// Open the menu on the very first click even when ForceRes is not the active app, instead of
    /// spending that click on activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        Trace.log("trigger.acceptsFirstMouse \(developmentName)", window: window)
        return isEnabled
    }
    override var canBecomeKeyView: Bool { isEnabled }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { setHovered(true) } }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseDown(with event: NSEvent) {
        Trace.log("trigger.mouseDown \(developmentName) clicks=\(event.clickCount)", window: window)
        // Swallow the press; the menu opens on mouse-up (see `mouseUp`).
        guard isEnabled else { super.mouseDown(with: event) ; return }
    }

    override func mouseUp(with event: NSEvent) {
        Trace.log("trigger.mouseUp \(developmentName)", window: window)
        guard isEnabled else { return super.mouseUp(with: event) }
        // A click must not leave the focus ring behind; it belongs to Tab users.
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        // Open on mouse-up, not mouse-down: a menu posted during the press is dismissed by the
        // release that follows it, so a normal click would only flash the menu.
        popUpMenu()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, let key = event.charactersIgnoringModifiers, key == " " || key == "\r" else {
            return super.keyDown(with: event)
        }
        popUpMenu()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        popUpMenu()
        return true
    }

    /// Builds the menu and runs it below the control. Returns when the menu has closed.
    func popUpMenu() {
        guard isEnabled, let menu = menuBuilder?() else { return }
        openChanged?(true)
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY + PanelMetrics.menuGap), in: self)
        openChanged?(false)
        // The pointer may have left while the menu was up without an exit event reaching us.
        if let window {
            setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        hoverChanged?(hovered)
    }

    // MARK: Focus ring

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: PanelMetrics.controlCornerRadius,
                     yRadius: PanelMetrics.controlCornerRadius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { needsDisplay = true }
        return resigned
    }
}
