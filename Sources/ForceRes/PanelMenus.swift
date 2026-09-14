import AppKit
import ForceResCore

/// Builds the panel's two AppKit menus (gear, refresh rate) from model state.
///
/// Pure functions of their inputs, so a test can assert titles, checkmarks, enabled flags and
/// key equivalents without a window. Each item's action is a closure kept alive by the item's
/// `representedObject`, and every closure runs on the main actor.
@MainActor
enum PanelMenus {
    static let aspectTitle = "Aspect Ratio"
    static let lowResolutionTitle = "Low Resolution (1x)"
    static let launchAtLoginTitle = "Launch at Login"
    static let launchAtLoginUnavailableTitle = "Launch at Login · requires the app bundle"
    static let approveLoginItemTitle = "Approve in System Settings › Login Items…"
    static let aboutTitle = "About ForceRes"
    static let quitTitle = "Quit ForceRes"

    /// The gear menu: Default Resolution and the aspect-ratio choice (when `display` is set), the
    /// scaling toggle, Launch at Login, an approval shortcut when Login Items needs one, Revert
    /// while a change is pending, About, Quit. Revert's title follows the countdown while open.
    static func settingsMenu(model: AppModel, display: DisplayInfo?,
                             showAbout: @escaping () -> Void) -> NSMenu {
        let menu = makeMenu()
        if let display {
            let entry = model.defaultResolutionItem(for: display)
            menu.addItem(item(entry.title, checked: entry.isChecked, enabled: entry.isEnabled) {
                model.select(preset: nil, for: display)
            })
            menu.addItem(.separator())
            menu.addItem(aspectItem(model: model, display: display))
        }
        // Aspect Ratio and Low Resolution both change what the presets mean, so they group
        // together, apart from the app's own settings below.
        let lowResolution = model.scaling == .lowResolution
        menu.addItem(item(lowResolutionTitle, checked: lowResolution) {
            model.setScaling(lowResolution ? .hiDPI : .lowResolution)
        })
        menu.addItem(.separator())
        let launchEnabled = model.launchAtLoginEnabled
        menu.addItem(item(model.isLaunchAtLoginAvailable ? launchAtLoginTitle : launchAtLoginUnavailableTitle,
                          checked: launchEnabled, enabled: model.isLaunchAtLoginAvailable) {
            model.setLaunchAtLogin(!launchEnabled)
        })
        if model.launchAtLoginRequiresApproval {
            menu.addItem(item(approveLoginItemTitle) { LaunchAtLogin.openSystemSettingsLoginItems() })
        }
        if model.pendingConfirmation != nil {
            let revert = item(revertTitle(seconds: model.secondsRemaining)) { model.revertPending() }
            observeRevertTitle(of: revert, model: model)
            menu.addItem(revert)
        }
        menu.addItem(.separator())
        menu.addItem(item(aboutTitle) { showAbout() })
        let quit = item(quitTitle) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
        return menu
    }

    /// The refresh-rate menu: one item per option in `state.options`, the current one checked.
    static func refreshMenu(state: RefreshControlState, select: @escaping (RefreshOption) -> Void) -> NSMenu {
        let menu = makeMenu()
        for option in state.options {
            menu.addItem(item(state.label(for: option), checked: option == state.current) { select(option) })
        }
        return menu
    }

    static func revertTitle(seconds: Int) -> String { "Revert (\(seconds)s)" }

    /// Items carry their own enabled flag rather than being validated against their target.
    private static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    /// "Aspect Ratio" with one checked entry per shape. A shape the display cannot show any size
    /// of is listed but disabled, so the set of choices never moves around.
    private static func aspectItem(model: AppModel, display: DisplayInfo) -> NSMenuItem {
        let current = model.aspect(for: display)
        let parent = NSMenuItem(title: aspectTitle, action: nil, keyEquivalent: "")
        let submenu = makeMenu()
        for aspect in AspectRatio.allCases {
            let offered = model.isAspectOffered(aspect, for: display)
            submenu.addItem(item(aspect.title, checked: aspect == current, enabled: offered) {
                model.setAspect(aspect, for: display)
            })
        }
        parent.submenu = submenu
        return parent
    }

    /// Keeps the Revert item's countdown live while its menu is open; stops once the item has
    /// been removed from a menu (the menu was discarded).
    private static func observeRevertTitle(of item: NSMenuItem, model: AppModel) {
        RevertCountdown(item: item, model: model).observe()
    }

    private static func item(_ title: String, checked: Bool = false, enabled: Bool = true,
                             action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        return item
    }
}

/// An `NSMenuItem` target wrapping a closure.
@MainActor
final class MenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() { action() }
}

/// Re-titles the Revert item on every countdown tick for as long as it sits in a menu.
/// Main-actor isolated (hence Sendable) so it can be captured by the observation callback.
@MainActor
private final class RevertCountdown {
    private weak var item: NSMenuItem?
    private let model: AppModel

    init(item: NSMenuItem, model: AppModel) {
        self.item = item
        self.model = model
    }

    /// The first call runs before the item joins its menu; later calls stop once it has left.
    func observe() {
        guard let item else { return }
        withObservationTracking {
            item.title = PanelMenus.revertTitle(seconds: model.secondsRemaining)
        } onChange: {
            Task { @MainActor in
                guard let item = self.item, item.menu != nil else { return }
                self.observe()
            }
        }
    }
}
