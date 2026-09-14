import AppKit
import ForceResCore
import Testing
@testable import ForceRes

/// The panel's AppKit menus, built from model state on the Odyssey G80SD dump.
@Suite("Panel menus")
@MainActor
struct PanelMenusTests {
    let odyssey = try! Fixtures.display(.m4OdysseyG80SD)

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try #require(menu.items.first { $0.title == title })
    }

    /// Sends the item's action to its target directly; `NSMenu.performActionForItem` goes
    /// through `NSApp`, which a test process does not have.
    private func perform(_ item: NSMenuItem) throws {
        let target = try #require(item.target as? NSObject)
        let action = try #require(item.action)
        _ = target.perform(action)
    }

    @Test func settingsMenuListsEveryEntryInOrder() throws {
        let h = Harness(displays: [odyssey])
        let menu = PanelMenus.settingsMenu(model: h.model, display: h.display, showAbout: {})
        #expect(titles(menu) == ["Default Resolution", "-",
                                 PanelMenus.aspectTitle, PanelMenus.lowResolutionTitle, "-",
                                 PanelMenus.launchAtLoginUnavailableTitle,
                                 "-", PanelMenus.aboutTitle, PanelMenus.quitTitle])
        #expect(!menu.autoenablesItems)
        let native = try item("Default Resolution", in: menu)
        #expect(native.isEnabled)
        #expect(native.state == .off)
        let lowResolution = try item(PanelMenus.lowResolutionTitle, in: menu)
        #expect(lowResolution.state == .off)
        let launch = try item(PanelMenus.launchAtLoginUnavailableTitle, in: menu)
        #expect(!launch.isEnabled)
        #expect(launch.state == .off)
        let quit = try item(PanelMenus.quitTitle, in: menu)
        #expect(quit.keyEquivalent == "q")
        #expect(quit.keyEquivalentModifierMask == .command)
        #expect(quit.isEnabled)
    }

    @Test func settingsMenuWithoutADisplayHasNoNativeEntry() {
        let h = Harness(displays: [odyssey])
        let menu = PanelMenus.settingsMenu(model: h.model, display: nil, showAbout: {})
        #expect(titles(menu).first == PanelMenus.lowResolutionTitle)
        #expect(!titles(menu).contains("Default Resolution"))
    }

    @Test func nativeIsCheckedWhenTheDisplayIsAlreadyNative() throws {
        let h = Harness(displays: [try Fixtures.display(.external1080p)])
        let menu = PanelMenus.settingsMenu(model: h.model, display: h.display, showAbout: {})
        let native = try item("Default Resolution", in: menu)
        #expect(native.state == .on)
    }

    @Test func lowResolutionItemReflectsAndTogglesScaling() throws {
        let h = Harness(displays: [odyssey], scaling: .lowResolution)
        var menu = PanelMenus.settingsMenu(model: h.model, display: h.display, showAbout: {})
        let checked = try item(PanelMenus.lowResolutionTitle, in: menu)
        #expect(checked.state == .on)
        try perform(checked)
        #expect(h.model.scaling == .hiDPI)

        menu = PanelMenus.settingsMenu(model: h.model, display: h.display, showAbout: {})
        let unchecked = try item(PanelMenus.lowResolutionTitle, in: menu)
        #expect(unchecked.state == .off)
        try perform(unchecked)
        #expect(h.model.scaling == .lowResolution)
    }

    @Test("The aspect submenu lists every shape, checks the current one, and switching relabels the tiles")
    func aspectSubmenu() throws {
        let h = Harness(displays: [odyssey])
        let menu = PanelMenus.settingsMenu(model: h.model, display: h.display, showAbout: {})
        let submenu = try #require(try item(PanelMenus.aspectTitle, in: menu).submenu)
        #expect(titles(submenu) == ["16:9", "16:10"])

        let current = h.model.aspect(for: h.display)
        for entry in submenu.items {
            #expect(entry.state == (entry.title == current.title ? .on : .off))
            #expect(entry.isEnabled, "\(entry.title) has sizes this display can show")
        }

        try perform(try item("16:10", in: submenu))
        #expect(h.model.aspect(for: h.display) == .sixteenByTen)
        #expect(h.model.presets(for: h.display).map(\.title) == ["800p", "900p", "1050p", "1200p"])
        #expect(h.service.applied.isEmpty, "picking a shape must not change the display")
    }

    @Test func pendingChangeDisablesNativeAndAddsRevert() throws {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)
        #expect(h.model.pendingConfirmation != nil)
        let menu = PanelMenus.settingsMenu(model: h.model, display: h.display, showAbout: {})
        let native = try item("Default Resolution · \(TileState.pendingNote)", in: menu)
        #expect(!native.isEnabled)
        let revert = try item(PanelMenus.revertTitle(seconds: h.model.secondsRemaining), in: menu)
        #expect(revert.isEnabled)
        #expect(titles(menu) == [native.title, "-",
                                 PanelMenus.aspectTitle, PanelMenus.lowResolutionTitle, "-",
                                 PanelMenus.launchAtLoginUnavailableTitle,
                                 revert.title, "-", PanelMenus.aboutTitle, PanelMenus.quitTitle])
        try perform(revert)
        #expect(h.model.pendingConfirmation == nil)
    }

    @Test func nativeActionSelectsNoPreset() throws {
        let h = Harness(displays: [odyssey])
        h.model.select(preset: .fullHD1080, for: h.display)
        h.model.keepPending()
        let menu = PanelMenus.settingsMenu(model: h.model, display: h.model.displays[0], showAbout: {})
        let native = try item("Default Resolution", in: menu)
        #expect(native.isEnabled)
        try perform(native)
        // Native restores the mode recorded before 1080p was applied (the fixture's 133).
        #expect(h.service.applied.last?.modeID == 133)
        #expect(h.model.pendingConfirmation?.description.contains("Default Resolution") == true)
    }

    @Test func aboutItemCallsBack() throws {
        let h = Harness(displays: [odyssey])
        var shown = false
        let menu = PanelMenus.settingsMenu(model: h.model, display: h.display, showAbout: { shown = true })
        try perform(try item(PanelMenus.aboutTitle, in: menu))
        #expect(shown)
    }

    @Test func refreshMenuListsOptionsWithTheCurrentOneChecked() throws {
        let h = Harness(displays: [odyssey])
        let state = h.model.refreshControlState(for: h.display)
        #expect(state.isEnabled)
        var selected: RefreshOption?
        let menu = PanelMenus.refreshMenu(state: state) { selected = $0 }
        #expect(menu.items.map(\.title) == state.options.map(state.label(for:)))
        #expect(menu.items.map(\.title) == ["Variable (48–240 Hertz)", "240 Hertz", "120 Hertz", "60 Hertz", "30 Hertz"])
        #expect(menu.items.map(\.state) == [.on, .off, .off, .off, .off])
        #expect(menu.items.map(\.isEnabled) == Array(repeating: true, count: 5))
        try perform(menu.items[2])
        #expect(selected == .fixed(hertz: 120))
    }

    @Test func refreshMenuIsEmptyForAVirtualMirror() {
        let state = RefreshControlState(options: [], current: nil, isProMotion: false, isVirtualMirror: true)
        let menu = PanelMenus.refreshMenu(state: state) { _ in }
        #expect(menu.items.isEmpty)
    }
}
