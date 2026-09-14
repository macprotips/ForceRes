import AppKit

/// Wires the live model to AppKit: accessory activation policy, error alerts, the status item
/// and its popover, the confirmation panel, and cleanup on quit, SIGTERM and SIGINT.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: ConfirmationPanelController?
    private var statusItemController: StatusItemController?
    private var signalSources: [any DispatchSourceSignal] = []
    /// Set while an error alert runs modally; further reports are logged and dropped.
    private var isPresentingError = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyDevelopmentAppearanceOverride()
        let model = AppEnvironment.model
        model.presentError = { [weak self] message in
            self?.presentError(message)
        }
        panelController = ConfirmationPanelController(model: model)
        model.start()
        statusItemController = StatusItemController(model: model)
        installSignalHandlers()
        scheduleDevelopmentPanelOpen()
        Log.app.info("ForceRes launched (bundle: \(Bundle.main.bundleIdentifier ?? "none"))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("applicationWillTerminate")
        AppEnvironment.model.cleanupForTermination()
    }

    private func presentError(_ message: String) {
        Log.ui.error("Alert: \(message)")
        guard !isPresentingError else {
            Log.ui.notice("Alert already showing; dropped: \(message)")
            return
        }
        isPresentingError = true
        defer { isPresentingError = false }
        Alerts.runModal(message, style: .warning)
    }

    /// `swift run` and `kill` deliver SIGTERM/SIGINT, which bypass `applicationWillTerminate`.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    Log.app.info("Signal \(sig) received; cleaning up")
                    AppEnvironment.model.cleanupForTermination()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Development hooks (debug builds only)

    /// `FORCERES_APPEARANCE=dark|light` forces the app's appearance at launch so both modes can
    /// be checked without changing the system setting.
    private func applyDevelopmentAppearanceOverride() {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["FORCERES_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #endif
    }

    /// `FORCERES_OPEN_PANEL=1` opens the popover about a second after launch, so a screenshot can
    /// be taken without clicking the status item; `FORCERES_OPEN_MENU=gear|refresh` then pops
    /// that control's menu a second later. `FORCERES_OPEN_MENU=status` alone pops the status
    /// item's right-click menu a second after launch.
    private func scheduleDevelopmentPanelOpen() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let menu = environment["FORCERES_OPEN_MENU"]
        let opensPanel = environment["FORCERES_OPEN_PANEL"] == "1"
        guard opensPanel || menu == "status" else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if opensPanel {
                self?.statusItemController?.showPopover()
                guard menu != nil else { return }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let menu else { return }
            self?.statusItemController?.developmentOpenMenu(named: menu)
        }
        #endif
    }
}
