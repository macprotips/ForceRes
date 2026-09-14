import AppKit
import ForceResDisplay
import Observation
import SwiftUI

/// Owns the menu bar status item and the popover it toggles.
///
/// One `NSStatusItem` and one `NSPopover` live for the whole process. The popover is
/// `.transient` (a click outside closes it); a left click on the status button toggles it and
/// the button stays highlighted while it is open. A right click or Control-click pops the
/// settings menu instead (`StatusItemAction`); `statusItem.menu` stays unset so the left click
/// keeps the panel. The glyph is the outline icon, swapped for the solid icon while
/// ForceRes is forcing a preset on any display.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel
    /// When the popover last closed; used to swallow the mouse-up of the click that closed it.
    private var lastCloseDate: Date?
    /// How long after a close the status button's action is treated as the same click.
    private static let reopenGuard: TimeInterval = 0.3
    private static let iconSize = NSSize(width: 18, height: 18)
    private var currentStyle: StatusIconStyle?
    /// Menus currently tracking (the panel's AppKit menus and the display picker's). The popover
    /// refuses to close while any is up, and a close asked for meanwhile waits for the last one.
    private var trackingMenus = 0
    private var closeAfterTracking = false
    private var menuObservers: [any NSObjectProtocol] = []
    /// Watches clicks that land in other apps while the panel is up. A transient popover already
    /// closes for most of them, but not for the menu bar, which is not another app's window.
    private var outsideClickMonitor: Any?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.toolTip = "ForceRes"
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        observeIconStyle()
        observeMenuTracking()

        let hosting = PanelHostingController(rootView: PanelView(model: model, dismiss: { [weak self] in
            self?.closePopover()
        }))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
    }

    // MARK: Icon

    private func observeIconStyle() {
        withObservationTracking {
            applyIconStyle(model.statusIconStyle)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIconStyle() }
        }
    }

    private func applyIconStyle(_ style: StatusIconStyle) {
        guard style != currentStyle else { return }
        currentStyle = style
        statusItem.button?.image = Self.image(for: style)
    }

    /// The template glyph for `style` from the module's resources, or the `display` SF Symbol
    /// when the resource bundle or file is missing.
    static func image(for style: StatusIconStyle) -> NSImage? {
        if let image = resourceImage(named: style.resourceName) {
            return image
        }
        Log.ui.error("Menu bar icon \(style.resourceName) missing from resources; using the display symbol")
        let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: "ForceRes")
        symbol?.isTemplate = true
        return symbol
    }

    /// Loads `name.png`, `name@2x.png` and `name@3x.png` into one template image.
    private static func resourceImage(named name: String) -> NSImage? {
        guard let bundle = resourceBundle else { return nil }
        let image = NSImage(size: iconSize)
        for suffix in ["", "@2x", "@3x"] {
            guard let url = bundle.url(forResource: name + suffix, withExtension: "png", subdirectory: "Resources") else {
                continue
            }
            for rep in NSImageRep.imageReps(withContentsOf: url) ?? [] {
                rep.size = iconSize
                image.addRepresentation(rep)
            }
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "ForceRes"
        return image
    }

    /// The SwiftPM resource bundle, looked up without `Bundle.module` so a missing bundle
    /// degrades to the fallback symbol instead of trapping.
    private static var resourceBundle: Bundle? {
        let name = "ForceRes_ForceRes.bundle"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ]
        for directory in candidates.compactMap({ $0 }) {
            let url = directory.appendingPathComponent(name)
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }

    // MARK: Popover

    /// Opens the popover under the status item. No-op when it is already shown.
    func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        Log.ui.info("Opening panel")
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A popover anchored to a status item follows the menu bar's appearance, not the app's;
        // honour an explicit app-level override if one is set.
        popover.appearance = NSApp.appearance
        // A status-item click does not activate an accessory app, and a popover in an inactive
        // app never becomes key: its first click would be spent bringing the app forward instead
        // of pressing the control under the pointer. Activate, then make the panel key.
        NSApp.activate()
        model.panelOpened(onDisplayID: Self.clickedDisplayID(button: button))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        let window = popover.contentViewController?.view.window
        window?.makeKey()
        Trace.log("showPopover", window: window)
        PanelHostingController.clearInitialFocus(in: window)
        button.highlight(true)
        watchForOutsideClicks()
    }

    /// Closes the panel on the next click that goes anywhere outside this app. Global monitors
    /// never see our own clicks, so the panel's own controls are unaffected.
    private func watchForOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.trackingMenus == 0 else { return }
                Trace.log("outside click")
                self.closePopover()
            }
        }
    }

    private func stopWatchingForOutsideClicks() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    /// The display the status item was clicked on.
    ///
    /// AppKit keeps one status bar window per screen when displays have separate Spaces, so the
    /// button's window belongs to the screen that received the click. The pointer's screen is the
    /// cross-check for the case where the button has no window yet, and it is independent of that
    /// private per-screen plumbing. `NSScreen.main` is deliberately not used: it follows keyboard
    /// focus, so it names the wrong display whenever another app is active elsewhere.
    static func clickedDisplayID(button: NSStatusBarButton?) -> String? {
        if let id = displayID(of: button?.window?.screen) { return id }
        let screens = NSScreen.screens
        let index = screenIndex(containing: NSEvent.mouseLocation, frames: screens.map(\.frame))
        return displayID(of: index.map { screens[$0] })
    }

    /// Index of the frame containing `point`, in AppKit's global space (bottom-left origin at the
    /// primary screen), so it holds for displays placed left, right, above or below.
    nonisolated static func screenIndex(containing point: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    /// The display UUID of `screen`. Resolved fresh on every click: a `CGDirectDisplayID` is not
    /// promised to survive a reconnect.
    private static func displayID(of screen: NSScreen?) -> String? {
        guard let screen else { return nil }
        let cgID: CGDirectDisplayID?
        if #available(macOS 26, *) {
            cgID = screen.cgDirectDisplayID
        } else {
            cgID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) }
        }
        return cgID.flatMap { CoreGraphicsDisplayService.uuidString(for: $0) }
    }

    /// Closes the popover. No-op when it is not shown; deferred until a tracking menu ends.
    func closePopover() {
        guard popover.isShown else { return }
        if trackingMenus > 0 {
            closeAfterTracking = true
            return
        }
        popover.performClose(nil)
    }

    // MARK: Menu tracking

    /// Counts open menus so `popoverShouldClose` can veto a transient close while one is up: the
    /// popover is neither key nor in the active app when a menu window opens from it.
    private func observeMenuTracking() {
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTrackingChanged(by: 1) }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTrackingChanged(by: -1) }
            },
        ]
    }

    private func menuTrackingChanged(by delta: Int) {
        trackingMenus = max(0, trackingMenus + delta)
        Trace.log("menuTracking=\(trackingMenus)")
        guard trackingMenus == 0, closeAfterTracking else { return }
        closeAfterTracking = false
        closePopover()
    }

    // MARK: Context menu

    /// The settings menu under the status item, for the main display (the panel's own selection
    /// lives in its view). Closes the panel first; the button highlights while the menu tracks.
    func showContextMenu() {
        guard let button = statusItem.button else { return }
        closePopover()
        Log.ui.info("Opening status item menu")
        let display = model.displays.first(where: \.isMain) ?? model.displays.first
        let menu = PanelMenus.settingsMenu(model: model, display: display,
                                           showAbout: { SettingsMenu.showAbout(dismiss: {}) })
        // Hand the menu to the status item and click it: AppKit then places and highlights the
        // menu exactly like any menu bar item's. Popping it manually mis-positions it near the
        // screen edge, which makes macOS scroll the first entries out of view.
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
        button.highlight(popover.isShown)
    }

    /// `FORCERES_OPEN_MENU=gear|refresh|status` (debug builds): pops the named control's menu
    /// through the same path as a mouse-down, for screenshots.
    func developmentOpenMenu(named name: String) {
        #if DEBUG
        if name == "status" {
            showContextMenu()
            return
        }
        guard let root = popover.contentViewController?.view else { return }
        var queue: [NSView] = [root]
        while let view = queue.first {
            queue.removeFirst()
            if let trigger = view as? MenuTriggerView, trigger.developmentName == name {
                Log.ui.info("Popping the \(name, privacy: .public) menu")
                trigger.popUpMenu()
                return
            }
            queue.append(contentsOf: view.subviews)
        }
        Log.ui.error("No \(name, privacy: .public) menu control in the panel")
        #endif
    }

    @objc private func statusButtonClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        Trace.log("statusButton \(event?.type.rawValue ?? 0) shown=\(popover.isShown)")
        switch StatusItemAction.forEvent(type: event?.type, modifiers: event?.modifierFlags ?? []) {
        case .contextMenu: showContextMenu()
        case .togglePanel: togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
            return
        }
        // A transient popover closes on the mouse-down of a click outside it, and the status
        // button's action then arrives on the mouse-up of that same click.
        if let lastCloseDate, Date().timeIntervalSince(lastCloseDate) < Self.reopenGuard {
            return
        }
        showPopover()
    }

    // MARK: NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        let window = popover.contentViewController?.view.window
        Log.ui.info("Panel shown; key window: \(window?.isKeyWindow ?? false), app active: \(NSApp.isActive)")
        PanelHostingController.clearInitialFocus(in: window)
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        Trace.log("popoverShouldClose tracking=\(trackingMenus)", window: popover.contentViewController?.view.window)
        if trackingMenus > 0 {
            Log.ui.info("Panel close refused while a menu is open")
            return false
        }
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        Trace.log("popoverDidClose tracking=\(trackingMenus)")
        Log.ui.info("Panel closed")
        stopWatchingForOutsideClicks()
        statusItem.button?.highlight(false)
        // The panel was the only reason to be frontmost; give focus back to the user's app.
        if trackingMenus == 0, NSApp.isActive { NSApp.deactivate() }
        // A close that slipped through while a menu was up was not the user's click outside,
        // so the next status-item click should reopen straight away.
        if trackingMenus == 0 {
            lastCloseDate = Date()
        }
    }
}

/// Hosts `PanelView` in the popover and keeps the popover from focusing its first control.
///
/// When a popover window becomes key it makes its first key view (the gear) first responder,
/// which draws a focus ring the moment the panel opens. Clearing the responder leaves the window
/// itself as first responder, so Tab still enters the key-view loop and shows rings as usual.
@MainActor
final class PanelHostingController: NSHostingController<PanelView> {
    override func viewDidAppear() {
        super.viewDidAppear()
        Self.clearInitialFocus(in: view.window)
    }

    /// Drops the focus a popover window gives its first key view on open. Called from both
    /// `viewDidAppear` and `popoverDidShow`, whichever runs after the window became key.
    static func clearInitialFocus(in window: NSWindow?) {
        guard let window else { return }
        window.initialFirstResponder = nil
        if window.firstResponder !== window {
            window.makeFirstResponder(nil)
        }
    }
}
