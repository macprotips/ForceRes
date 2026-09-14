import AppKit
import CoreGraphics
import ForceResDisplay
import Observation
import SwiftUI

/// A non-activating floating panel that can still take keyboard focus for Return/Esc.
final class ConfirmationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows `ConfirmationPanel` while `model.pendingConfirmation` is set and closes it when the
/// change resolves. The panel is centred on the affected display when it can be resolved.
@MainActor
final class ConfirmationPanelController {
    private let model: AppModel
    private var panel: ConfirmationPanel?

    init(model: AppModel) {
        self.model = model
        observe()
    }

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func sync() {
        guard let pending = model.pendingConfirmation else {
            if panel != nil {
                Log.ui.info("Closing confirmation panel")
                panel?.orderOut(nil)
                panel = nil
            }
            return
        }
        guard panel == nil else { return }
        Log.ui.info("Showing confirmation panel for \(pending.displayID)")
        let panel = ConfirmationPanel(
            contentRect: NSRect(origin: .zero, size: PanelMetrics.confirmationInitialSize),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ConfirmationView(model: model))
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        center(panel, on: Self.screen(forDisplayUUID: pending.displayID))
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
    }

    private func center(_ panel: NSPanel, on screen: NSScreen?) {
        guard let frame = (screen ?? NSScreen.main)?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    }

    /// Display UUID → `CGDirectDisplayID` → the `NSScreen` whose `NSScreenNumber` matches.
    static func screen(forDisplayUUID uuid: String) -> NSScreen? {
        guard let id = try? CoreGraphicsDisplayService.directDisplayID(for: uuid) else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
    }
}
