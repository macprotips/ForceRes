import AppKit
import Foundation
import ForceResCore
import ForceResDisplay
import Observation

/// The app's single source of truth: connected displays, the scaling toggle, the pending
/// confirmation, and the virtual mirrors we own.
///
/// All members are main-actor isolated. Collaborators are injected so tests can drive the model
/// with `MockDisplayService`, `InMemoryPreferencesStore`, a fake virtual-display provider and a
/// manual clock.
@MainActor @Observable
final class AppModel {
    /// How long the user has to confirm a change before it auto-reverts.
    static let confirmationSeconds = 15
    /// Minimum spacing between two silent re-applies on the same display.
    static let reconcileCooldown: TimeInterval = 5
    /// Delay between `didWakeNotification` and the wake-up reconcile.
    static let wakeReconcileDelay: Duration = .seconds(2)

    /// A virtual display we created and mirrored onto a physical display.
    struct ActiveVirtualMirror: Equatable, Sendable {
        var virtualID: String
        var preset: ResolutionPreset
        var plan: VirtualDisplayPlan
        /// The physical display's pre-mirror snapshot; the mode source while it mirrors, since a
        /// mirrored display reports the master's expanded mode list (docs/RESEARCH.md addendum).
        var physical: DisplayInfo
    }

    // MARK: State

    /// Physical displays only (virtual displays, ours or third-party, are filtered out), in
    /// CoreGraphics order.
    private(set) var displays: [DisplayInfo] = []
    /// The "Low Resolution (1x)" toggle, mirrored from the store.
    private(set) var scaling: ScalingPreference
    /// The change awaiting Keep/Revert, if any.
    private(set) var pendingConfirmation: PendingChange?
    /// Seconds left on the countdown while `pendingConfirmation` is set.
    private(set) var secondsRemaining = 0
    /// The most recent user-facing error, also handed to `presentError`.
    private(set) var lastError: String?
    /// `true` when the private virtual-display route resolved at runtime.
    let isVirtualSupported: Bool
    /// Active virtual mirrors keyed by the physical display's UUID.
    private(set) var activeVirtualMirrors: [String: ActiveVirtualMirror] = [:]
    /// Saved choices, mirrored from the store so views can observe them.
    private(set) var savedChoices: [String: DisplayChoice] = [:]
    /// Per display: the caption shown when the saved rate was unavailable in the family last
    /// applied and the highest rate was used instead (`RefreshControlState.fallbackNote`).
    private(set) var refreshFallbackNotes: [String: String] = [:]
    /// Whether the app is registered as a login item (only meaningful when bundled).
    private(set) var launchAtLoginEnabled = false
    /// `true` when registration is waiting for the user's approval in System Settings.
    private(set) var launchAtLoginRequiresApproval = false
    /// `false` when running outside an app bundle, where `SMAppService` cannot register.
    let isLaunchAtLoginAvailable: Bool
    /// `true` while a select, reconcile or virtual-mirror change is in progress.
    var isBusy: Bool { isApplying }
    private var isApplying = false

    /// Called on the main actor whenever `lastError` is set; the delegate hooks up an `NSAlert`.
    var presentError: (@MainActor (String) -> Void)?

    // MARK: Collaborators

    @ObservationIgnored private let service: any DisplayService
    @ObservationIgnored private let store: any PreferencesStore
    @ObservationIgnored private let virtualProvider: (any VirtualDisplayProviding)?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var reconfigurationTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileFollowUpTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var lastReconcileApply: [String: Date] = [:]
    @ObservationIgnored private var didOpenLoginItemsSettings = false
    /// Virtual displays we destroyed that this process may keep listing for a while (measured up
    /// to ~30 s after a mirror). Each is hidden from `displays` until it has been seen in a
    /// snapshot and then vanished, or until it is older than `retiredVirtualTTL`.
    @ObservationIgnored private var retiredVirtualIDs: [String: RetiredVirtual] = [:]
    private struct RetiredVirtual {
        var retiredAt: Date
        var seenInSnapshot = false
    }
    static let retiredVirtualTTL: TimeInterval = 120

    /// - Parameters:
    ///   - service: display enumeration and configuration.
    ///   - store: persisted choices and the scaling toggle.
    ///   - virtualProvider: nil when the private virtual-display classes are missing.
    ///   - clock: drives the countdown, the wake delay and the reconcile follow-up; tests pass a
    ///     manual clock.
    ///   - now: wall clock for cooldowns; tests pass a fixed value.
    ///   - launchAtLoginAvailable: defaults to `LaunchAtLogin.isAvailable`.
    init(service: any DisplayService,
         store: any PreferencesStore,
         virtualProvider: (any VirtualDisplayProviding)?,
         clock: any Clock<Duration> = ContinuousClock(),
         now: @escaping @Sendable () -> Date = { Date() },
         launchAtLoginAvailable: Bool = LaunchAtLogin.isAvailable) {
        self.service = service
        self.store = store
        self.virtualProvider = virtualProvider
        self.clock = clock
        self.now = now
        self.isVirtualSupported = virtualProvider != nil
        self.scaling = store.scalingPreference
        self.savedChoices = store.allChoices
        self.isLaunchAtLoginAvailable = launchAtLoginAvailable
        if launchAtLoginAvailable {
            let state = LaunchAtLoginState(status: LaunchAtLogin.status)
            launchAtLoginEnabled = state.isOn
            launchAtLoginRequiresApproval = state.requiresApproval
        }
    }

    // MARK: Lifecycle

    /// Loads displays, re-applies saved choices, and starts listening for reconfiguration and
    /// sleep/wake. Called once from the app delegate; tests call the pieces directly.
    func start() {
        Log.app.info("Starting model; virtual displays supported: \(self.isVirtualSupported)")
        refresh()
        reconcile()
        // Subscribe synchronously so the CoreGraphics callback is registered on the main thread
        // (and so no event emitted before the task first runs is lost).
        let reconfigurations = service.reconfigurations()
        reconfigurationTask = Task { [weak self] in
            for await event in reconfigurations {
                guard let self else { break }
                guard case .ended(let ids, let flags) = event else { continue }
                Log.display.info("Reconfiguration ended for \(ids.count) display(s), flags 0x\(String(flags, radix: 16))")
                if isApplying {
                    Log.display.notice("Reconfiguration arrived while applying; skipping reconcile")
                    continue
                }
                refresh()
                reconcile()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleDidWake() }
            },
        ]
    }

    /// Reverts any unconfirmed change, releases every mirror and virtual display, then puts each
    /// connected display back in the mode it had before ForceRes first changed it. Synchronous
    /// so it can run from `applicationWillTerminate` and signal handlers; a second call is a
    /// no-op. Saved choices survive, so the next launch re-applies them (and records the
    /// originals afresh in `reconcile`).
    func cleanupForTermination() {
        Log.app.info("Cleanup for termination")
        countdownTask?.cancel()
        countdownTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        reconcileFollowUpTask?.cancel()
        reconcileFollowUpTask = nil
        // Stop listening first: the teardown below emits `.ended`, which must not reconcile a
        // saved choice back into a fresh virtual mirror while the process is on its way out.
        reconfigurationTask?.cancel()
        reconfigurationTask = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers = []
        revertPending(final: true)
        teardownAllVirtualMirrors()
        virtualProvider?.destroyAll()
        restoreOriginalModes()
    }

    /// Applies each connected display's recorded original mode (permanent, session fallback) and
    /// forgets the record once the display is on it, so a second call applies nothing. No
    /// countdown, no mirror, no alert: a failure is logged and the record kept for the next run.
    private func restoreOriginalModes() {
        for display in displays {
            guard let originalID = store.originalModeID(forDisplayID: display.id) else { continue }
            let currentID = (try? service.currentModeID(for: display.id)) ?? display.currentModeID
            if currentID == originalID {
                Log.display.info("Quit: \(display.name) already on original mode \(originalID)")
            } else {
                do {
                    let persistence = try service.applyPreferringPermanent(modeID: originalID, to: display.id)
                    Log.display.info("Quit: restored \(display.name) to original mode \(originalID) (\(persistence.rawValue))")
                } catch {
                    Log.display.error("Quit: restoring \(display.name) to mode \(originalID) failed: \(error.localizedDescription)")
                    continue
                }
            }
            store.setOriginalModeID(nil, forDisplayID: display.id)
        }
    }

    // MARK: Snapshot

    /// Reloads the display list, dropping virtual displays and releasing virtual mirrors whose
    /// physical display has gone away. A countdown whose display vanished ends without a revert.
    func refresh() {
        do {
            let virtualIDs = Set(virtualProvider?.activeDisplayIDs ?? [])
            let snapshot = try service.snapshot()
            let snapshotIDs = Set(snapshot.map(\.id))
            let current = now()
            for (id, entry) in retiredVirtualIDs {
                if snapshotIDs.contains(id) {
                    retiredVirtualIDs[id]?.seenInSnapshot = true
                } else if entry.seenInSnapshot || current.timeIntervalSince(entry.retiredAt) > Self.retiredVirtualTTL {
                    retiredVirtualIDs.removeValue(forKey: id)
                }
            }
            let physical = snapshot.filter {
                $0.isPhysical && !virtualIDs.contains($0.id) && retiredVirtualIDs[$0.id] == nil
            }
            if physical != displays { displays = physical }
            let present = Set(displays.map(\.id))
            refreshFallbackNotes = refreshFallbackNotes.filter { present.contains($0.key) }
            if let pending = pendingConfirmation, !present.contains(pending.displayID) {
                Log.display.notice("Display \(pending.displayID) vanished during a countdown; ending it without revert")
                finishCountdown()
            }
            for (physicalID, mirror) in activeVirtualMirrors.sorted(by: { $0.key < $1.key }) {
                if !present.contains(physicalID) {
                    Log.virtual.info("Physical display \(physicalID) vanished; releasing its virtual mirror")
                    teardownVirtualMirror(for: physicalID)
                } else if !virtualIDs.contains(mirror.virtualID) {
                    // The helper died on its own: drop the tracking and free the physical display
                    // from the (now master-less) mirror set.
                    Log.virtual.error("Virtual display \(mirror.virtualID) is gone; un-mirroring \(physicalID)")
                    teardownVirtualMirror(for: physicalID)
                }
            }
        } catch {
            report(error, context: "Reading displays")
        }
    }

    // MARK: Availability and menu state

    /// `ModeSelector.availability` for the current scaling preference, evaluated against the
    /// display's own mode list (the pre-mirror snapshot while it mirrors one of our virtual displays).
    func availability(of preset: ResolutionPreset, for display: DisplayInfo) -> PresetAvailability {
        let physical = physicalView(of: display)
        return ModeSelector.availability(of: preset, scaling: scaling, for: physical,
                                         preferredModeIDs: preferredModeIDs(for: physical))
    }

    /// Tie-break ids for `ModeSelector`: the recorded original mode, then the current mode.
    private func preferredModeIDs(for physical: DisplayInfo) -> [Int32] {
        [store.originalModeID(forDisplayID: physical.id), physical.currentModeID].compactMap { $0 }
    }

    /// The mode "Default Resolution" restores on `display`: the recorded original mode when it is still
    /// usable, otherwise the display's default mode (`ModeSelector.restoreMode`).
    private func restoreMode(for physical: DisplayInfo) -> DisplayModeInfo? {
        ModeSelector.restoreMode(in: physical.modes, originalModeID: store.originalModeID(forDisplayID: physical.id))
    }

    /// Records the display's current mode as its original the first time ForceRes is about to
    /// change it. Skipped when an original is already recorded, or when the current mode is
    /// itself the result of a saved ForceRes choice (so a re-applied preset is never mistaken
    /// for the user's own setup).
    /// - Parameter trustSavedChoice: the reconcile path passes `true`: the quit restore cleared
    ///   the original, so a display that does not yet satisfy its saved choice is in the user's
    ///   own mode even though a choice exists.
    private func recordOriginalModeIfNeeded(for physical: DisplayInfo, trustSavedChoice: Bool = false) {
        guard store.originalModeID(forDisplayID: physical.id) == nil,
              trustSavedChoice || store.choice(forDisplayID: physical.id) == nil,
              let currentModeID = physical.currentModeID else { return }
        store.setOriginalModeID(currentModeID, forDisplayID: physical.id)
        Log.display.info("Recorded original mode \(currentModeID) for \(physical.name)")
    }

    /// `display` as the mode picker must see it: while it mirrors a virtual display, the snapshot
    /// recorded before the mirror was set; otherwise `display` itself.
    private func physicalView(of display: DisplayInfo) -> DisplayInfo {
        activeVirtualMirrors[display.id]?.physical ?? display
    }

    /// The preset currently in effect on `display`: the active virtual mirror's preset, else the
    /// preset whose pixel size matches the current mode.
    func currentPreset(for display: DisplayInfo) -> ResolutionPreset? {
        if let mirror = activeVirtualMirrors[display.id] { return mirror.preset }
        return ModeSelector.currentPreset(for: display, scaling: scaling)?.preset
    }

    /// Title of the gear menu entry that restores the recorded original mode.
    nonisolated static let defaultResolutionTitle = "Default Resolution"

    /// Label, enabled flag and checkmark for the "Default Resolution" entry of `display`. Checked
    /// when the display is in the mode it would restore and no virtual mirror is active;
    /// disabled, with the tiles' note, while a change is pending or applying.
    func defaultResolutionItem(for display: DisplayInfo) -> MenuItemState {
        let title = Self.defaultResolutionTitle
        guard let restore = restoreMode(for: physicalView(of: display)) else {
            return MenuItemState(title: "\(title) · \(UnavailableReason.noModes.message)", isEnabled: false, isChecked: false)
        }
        let checked = activeVirtualMirrors[display.id] == nil && display.currentModeID == restore.id
        if pendingConfirmation != nil {
            return MenuItemState(title: "\(title) · \(TileState.pendingNote)", isEnabled: false, isChecked: checked)
        }
        if isBusy {
            return MenuItemState(title: "\(title) · \(TileState.busyNote)", isEnabled: false, isChecked: checked)
        }
        return MenuItemState(title: title, isEnabled: true, isChecked: checked)
    }

    /// The display the panel controls. Set when the panel opens to the screen it opened on, so a
    /// click on a second screen's menu bar adjusts that screen, and changeable with the picker.
    var selectedDisplayID: String?

    /// Aims the panel at the screen it was opened from, falling back to the main display.
    func panelOpened(onDisplayID displayID: String?) {
        let displays = self.displays
        if let displayID, displays.contains(where: { $0.id == displayID }) {
            selectedDisplayID = displayID
        } else {
            selectedDisplayID = displays.first(where: \.isMain)?.id ?? displays.first?.id
        }
    }

    /// The shape of presets the panel shows for `display`: the user's saved choice, else the shape
    /// of the resolution it is already on, else 16:9.
    func aspect(for display: DisplayInfo) -> AspectRatio {
        if let saved = store.aspect(forDisplayID: display.id) { return saved }
        if let current = currentPreset(for: display) { return current.aspect }
        return .sixteenByNine
    }

    /// The four presets the tile row shows for `display`.
    func presets(for display: DisplayInfo) -> [ResolutionPreset] {
        aspect(for: display).presets
    }

    /// Switches which shape the tile row offers. Relabels the tiles; never changes the display.
    func setAspect(_ aspect: AspectRatio, for display: DisplayInfo) {
        guard aspect != self.aspect(for: display) else { return }
        Log.ui.info("Aspect ratio for \(display.name): \(aspect.title)")
        store.setAspect(aspect, forDisplayID: display.id)
        refreshFallbackNotes[display.id] = nil
    }

    /// Whether `aspect` has at least one preset this display can show.
    func isAspectOffered(_ aspect: AspectRatio, for display: DisplayInfo) -> Bool {
        aspect.presets.contains { tileState($0, for: display).isEnabled || currentPreset(for: display) == $0 }
    }

    /// `TileState` for one preset tile of `display`.
    func tileState(_ preset: ResolutionPreset, for display: DisplayInfo) -> TileState {
        TileState(preset: preset,
                  availability: availability(of: preset, for: display),
                  isSelected: currentPreset(for: display) == preset,
                  isVirtualSupported: isVirtualSupported,
                  scaling: scaling,
                  isConfirmationPending: pendingConfirmation != nil,
                  isBusy: isBusy)
    }

    /// `RefreshControlState` for `display`: the rates it enumerates for the resolution in effect
    /// (the current mode's family), disabled while it mirrors a virtual display, while a change is
    /// pending or applying, when the current rate cannot be verified, or when there is nothing
    /// to choose between.
    func refreshControlState(for display: DisplayInfo) -> RefreshControlState {
        if activeVirtualMirrors[display.id] != nil {
            return RefreshControlState(options: [], current: nil, isProMotion: false, isVirtualMirror: true)
        }
        return RefreshControlState(options: ModeSelector.availableRefreshOptions(for: nil, scaling: scaling, in: display),
                                   current: ModeSelector.currentRefreshOption(for: display),
                                   isProMotion: isProMotion(display),
                                   isConfirmationPending: pendingConfirmation != nil,
                                   isBusy: isBusy,
                                   fallbackNote: refreshFallbackNotes[display.id])
    }

    /// Built-in panels whose variable entry is a ProMotion one are labelled "ProMotion".
    private func isProMotion(_ display: DisplayInfo) -> Bool {
        display.isBuiltIn && display.modes.contains { $0.isProMotion == true }
    }

    /// The fallback caption for `display`, if its last applied choice could not honour its rate.
    func refreshFallbackNote(for display: DisplayInfo) -> String? {
        refreshFallbackNotes[display.id]
    }

    /// The saved refresh preference for `display`, carried over when the preset changes.
    private func savedRefresh(for displayID: String) -> RefreshPreference {
        store.choice(forDisplayID: displayID)?.refresh ?? .highest
    }

    /// The native mode `choice` asks for on `display` (its own mode list): the preset's pick, or
    /// for a rate-only choice (`preset == nil`) the refresh pick within the current mode's family.
    /// A rate-only choice never changes the resolution, so it is anchored on whatever the display
    /// runs now, never on the recorded original. `nil` when no native mode fits.
    private func targetSelection(for display: DisplayInfo, choice: DisplayChoice) -> ModeSelection? {
        let preferred = preferredModeIDs(for: display)
        if let preset = choice.preset {
            return ModeSelector.select(for: preset, scaling: choice.scaling, in: display.modes,
                                       preferredModeIDs: preferred, refresh: choice.refresh)
        }
        guard let current = display.currentMode else { return nil }
        return ModeSelector.select(inFamilyOf: current, in: display.modes, preferredModeIDs: preferred,
                                   refresh: choice.refresh)
    }

    /// `true` when `display` already delivers `choice`: an active virtual mirror for the same
    /// preset, or a current mode that `ModeSelector.isSatisfied` accepts for the choice's target
    /// (`.highest` needs the family's top rate, on either twin, so fixed/variable twins never
    /// churn). The single rule behind select, reconcile and the control's checkmark.
    func isSatisfied(_ display: DisplayInfo, by choice: DisplayChoice) -> Bool {
        if let mirror = activeVirtualMirrors[display.id] { return mirror.preset == choice.preset }
        guard let current = display.currentMode,
              let target = targetSelection(for: display, choice: choice) else { return false }
        return ModeSelector.isSatisfied(current: current, by: target, refresh: choice.refresh)
    }

    /// Solid while any connected display has a ForceRes preset in effect, else outline.
    var statusIconStyle: StatusIconStyle {
        StatusIconStyle.resolve(choices: displays.map { savedChoices[$0.id] },
                                hasActiveMirror: !activeVirtualMirrors.isEmpty)
    }

    // MARK: User actions

    /// Applies `preset` to `display` and starts the confirmation countdown. `nil` is "Default
    /// Resolution":
    /// restore the mode the display was in before ForceRes first changed it (or the default mode
    /// when none was recorded), and forget the saved choice on Keep.
    func select(preset: ResolutionPreset?, for display: DisplayInfo) {
        guard pendingConfirmation == nil else {
            Log.display.notice("Ignoring selection while a confirmation is pending")
            return
        }
        guard !isApplying else {
            Log.display.notice("Ignoring selection while a change is being applied")
            return
        }
        isApplying = true
        defer { isApplying = false }
        // Never pick a mode id from the expanded list a mirrored display reports.
        let display = physicalView(of: display)
        do {
            if let preset {
                // The display's saved rate carries over to the new preset.
                let choice = DisplayChoice(preset: preset, scaling: scaling, refresh: savedRefresh(for: display.id))
                switch availability(of: preset, for: display) {
                case .available:
                    guard let selection = targetSelection(for: display, choice: choice) else { return }
                    noteRefreshOutcome(selection, choice: choice, for: display.id)
                    try applyNativeMode(selection.mode, choice: choice,
                                        description: ChangeDescription.nativeMode(display: display, preset: preset,
                                                                                  mode: selection.mode),
                                        to: display)
                case .needsVirtualDisplay(let plan):
                    try applyVirtualMirror(preset: preset, plan: plan, to: display)
                case .unavailable(let reason):
                    Log.display.notice("\(preset.title) unavailable on \(display.name): \(reason.message)")
                }
            } else {
                // An untouched display is already in its original mode: record it first so
                // "Default Resolution" restores it rather than the default-flagged mode.
                recordOriginalModeIfNeeded(for: display)
                guard let mode = restoreMode(for: display) else {
                    Log.display.error("No mode to restore for \(display.name)")
                    return
                }
                try applyNativeMode(mode, choice: nil,
                                    description: ChangeDescription.nativeMode(display: display, preset: nil, mode: mode),
                                    to: display)
            }
        } catch {
            report(error, context: "Changing \(display.name)")
        }
    }

    /// Applies `refresh` to the resolution in effect on `display` (the current mode's family) and
    /// starts the confirmation countdown; a rate the display already runs is only recorded. The
    /// preference persists with the preset in effect, or with `preset == nil` on any other
    /// resolution. Ignored while a confirmation is pending, a change is being applied, or the
    /// display mirrors a virtual display.
    func select(refresh: RefreshPreference, for display: DisplayInfo) {
        guard pendingConfirmation == nil else {
            Log.display.notice("Ignoring refresh selection while a confirmation is pending")
            return
        }
        guard !isApplying else {
            Log.display.notice("Ignoring refresh selection while a change is being applied")
            return
        }
        guard activeVirtualMirrors[display.id] == nil else {
            Log.display.notice("Ignoring refresh selection on \(display.name) while it mirrors a virtual display")
            return
        }
        guard display.currentMode != nil else {
            Log.display.error("Refresh selection on \(display.name) with no current mode")
            return
        }
        isApplying = true
        defer { isApplying = false }
        let inEffect = ModeSelector.currentPreset(for: display, scaling: scaling)
        let variant: ScalingPreference = inEffect.map { $0.exact ? scaling : (scaling == .hiDPI ? .lowResolution : .hiDPI) } ?? scaling
        let choice = DisplayChoice(preset: inEffect?.preset, scaling: variant, refresh: refresh)
        guard let selection = targetSelection(for: display, choice: choice) else {
            Log.display.error("No mode for \(refresh.debugDescription) on \(display.name)")
            return
        }
        noteRefreshOutcome(selection, choice: choice, for: display.id)
        do {
            try applyNativeMode(selection.mode, choice: choice,
                                description: ChangeDescription.refreshChange(
                                    display: display, preset: choice.preset, mode: selection.mode,
                                    isProMotion: isProMotion(display)),
                                to: display)
        } catch {
            report(error, context: "Changing \(display.name)")
        }
    }

    /// Records or clears the fallback caption for a selection made for `choice`: the rate was
    /// missing from the family, or could not be verified (`RefreshOutcome.unverified`).
    private func noteRefreshOutcome(_ selection: ModeSelection, choice: DisplayChoice, for displayID: String) {
        switch selection.refreshOutcome {
        case .exact:
            refreshFallbackNotes[displayID] = nil
        case .fellBackToHighest:
            refreshFallbackNotes[displayID] = RefreshControlState.fallbackNote(refresh: choice.refresh, preset: choice.preset)
        case .unverified:
            refreshFallbackNotes[displayID] = RefreshControlState.unverifiedFallbackNote
        }
    }

    /// Re-derives the caption for `displayID` from its saved choice once a change is kept or
    /// reverted, so a caption never outlives the selection that produced it.
    private func recomputeRefreshFallbackNote(for displayID: String) {
        guard let display = displays.first(where: { $0.id == displayID }),
              let choice = store.choice(forDisplayID: displayID),
              activeVirtualMirrors[displayID] == nil,
              let selection = targetSelection(for: display, choice: choice) else {
            refreshFallbackNotes[displayID] = nil
            return
        }
        noteRefreshOutcome(selection, choice: choice, for: displayID)
    }

    /// Confirms the pending change: persists the choice and makes the mode permanent. Other
    /// displays whose reconcile was held back while the change was pending are reconciled after.
    func keepPending() {
        guard let pending = pendingConfirmation else { return }
        finishCountdown()
        do {
            try pending.keep()
            Log.display.info("Kept: \(pending.description)")
        } catch {
            report(error, context: "Keeping settings")
        }
        recomputeRefreshFallbackNote(for: pending.displayID)
        reconcile()
    }

    /// Undoes the pending change without persisting anything.
    /// - Parameter final: the process is terminating or the Mac is going to sleep, so a virtual
    ///   mirror the change replaced is not recreated (no helper is ever spawned on the way out).
    func revertPending(final: Bool = false) {
        guard let pending = pendingConfirmation else { return }
        finishCountdown()
        do {
            try pending.revert(final)
            Log.display.info("Reverted\(final ? " (final)" : ""): \(pending.description)")
        } catch {
            report(error, context: "Reverting")
        }
        recomputeRefreshFallbackNote(for: pending.displayID)
    }

    /// Updates the scaling toggle. Applied choices are left alone until the user picks again.
    func setScaling(_ preference: ScalingPreference) {
        scaling = preference
        store.scalingPreference = preference
        Log.display.info("Scaling preference: \(preference.rawValue)")
    }

    /// Registers or unregisters the login item. A registration that macOS parks in
    /// "requires approval" keeps the toggle on and opens Login Items once.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard isLaunchAtLoginAvailable else { return }
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            report(error, context: "Launch at Login")
        }
        let state = LaunchAtLoginState(status: LaunchAtLogin.status)
        launchAtLoginEnabled = state.isOn
        launchAtLoginRequiresApproval = state.requiresApproval
        Log.app.info("Launch at login: \(self.launchAtLoginEnabled), requires approval: \(self.launchAtLoginRequiresApproval)")
        if state.requiresApproval, !didOpenLoginItemsSettings {
            didOpenLoginItemsSettings = true
            LaunchAtLogin.openSystemSettingsLoginItems()
        }
    }

    // MARK: Reconcile

    /// Re-applies every saved choice whose display is not already in that state. Silent (no
    /// confirmation); skipped entirely while a confirmation is pending or a change is being
    /// applied. A display skipped for its cooldown gets one follow-up reconcile once it lapses.
    func reconcile() {
        guard pendingConfirmation == nil else { return }
        guard !isApplying else {
            Log.display.notice("Reconcile requested while applying; skipped")
            return
        }
        isApplying = true
        defer { isApplying = false }
        var skippedForCooldown = false
        for display in displays {
            guard let choice = store.choice(forDisplayID: display.id) else { continue }
            if let last = lastReconcileApply[display.id], now().timeIntervalSince(last) < Self.reconcileCooldown {
                skippedForCooldown = true
                continue
            }
            do {
                if try reconcile(display, to: choice) {
                    lastReconcileApply[display.id] = now()
                }
            } catch {
                lastReconcileApply[display.id] = now()
                report(error, context: "Restoring \(display.name)")
            }
        }
        if skippedForCooldown { scheduleReconcileFollowUp() }
    }

    private func scheduleReconcileFollowUp() {
        reconcileFollowUpTask?.cancel()
        Log.display.info("Reconcile deferred by cooldown; follow-up in \(Self.reconcileCooldown) s")
        reconcileFollowUpTask = Task { [weak self] in
            guard let clock = self?.clock else { return }
            do { try await clock.sleep(for: .seconds(Self.reconcileCooldown)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            reconcileFollowUpTask = nil
            refresh()
            reconcile()
        }
    }

    /// - Returns: `true` when something was applied.
    private func reconcile(_ display: DisplayInfo, to choice: DisplayChoice) throws -> Bool {
        if choice.preset == nil, choice.refresh == .highest {
            // Plain Native choices are no longer persisted; drop one saved by an earlier build and
            // release any mirror that contradicts it.
            removeChoice(forDisplayID: display.id)
            guard activeVirtualMirrors[display.id] != nil else { return false }
            Log.virtual.info("Reconcile: \(display.name) has a stale native choice; releasing virtual mirror")
            teardownVirtualMirror(for: display.id)
            refresh()
            return true
        }
        if activeVirtualMirrors[display.id] != nil {
            // Never pick a mode from a mirrored display's expanded list: either the mirror already
            // satisfies the choice, or release it and let a later reconcile finish the job once
            // macOS has restored the panel.
            if isSatisfied(display, by: choice) { return false }
            Log.virtual.info("Reconcile: \(display.name) saved choice changed; releasing virtual mirror")
            teardownVirtualMirror(for: display.id)
            refresh()
            return true
        }
        let title = choice.preset?.title ?? AppModel.defaultResolutionTitle
        if let selection = targetSelection(for: display, choice: choice) {
            noteRefreshOutcome(selection, choice: choice, for: display.id)
            if isSatisfied(display, by: choice) { return false }
            recordOriginalModeIfNeeded(for: display, trustSavedChoice: true)
            Log.display.info("Reconcile: \(display.name) → \(title) mode \(selection.mode.id) (\(choice.refresh.debugDescription))")
            try service.applyPreferringPermanent(modeID: selection.mode.id, to: display.id)
            refresh()
            return true
        }
        guard let preset = choice.preset else { return false }
        switch ModeSelector.availability(of: preset, scaling: choice.scaling, for: display,
                                         preferredModeIDs: preferredModeIDs(for: display)) {
        case .available:
            return false
        case .needsVirtualDisplay(let plan):
            guard isVirtualSupported else { return false }
            recordOriginalModeIfNeeded(for: display, trustSavedChoice: true)
            Log.virtual.info("Reconcile: \(display.name) → \(preset.title) via virtual mirror")
            try activateVirtualMirror(preset: preset, plan: plan, on: display)
            refresh()
            return true
        case .unavailable:
            return false
        }
    }

    // MARK: Sleep / wake

    /// Reverts any unconfirmed change, then releases every virtual mirror (macOS cannot sleep a
    /// mirrored panel cleanly). Saved choices stay, so `handleDidWake` recreates them.
    func handleWillSleep() {
        Log.app.info("System will sleep; reverting pending change and releasing virtual mirrors")
        wakeTask?.cancel()
        reconcileFollowUpTask?.cancel()
        reconcileFollowUpTask = nil
        revertPending(final: true)
        teardownAllVirtualMirrors(holdReconcile: false)
        virtualProvider?.destroyAll()
    }

    /// Schedules a reconcile shortly after wake, once CoreGraphics has settled.
    func handleDidWake() {
        Log.app.info("System woke; reconcile in \(Self.wakeReconcileDelay.components.seconds) s")
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            guard let clock = self?.clock else { return }
            do { try await clock.sleep(for: Self.wakeReconcileDelay) } catch { return }
            self?.refresh()
            self?.reconcile()
        }
    }

    // MARK: Applying changes

    /// Persists a kept change: a preset, or a Native display with a rate preference, becomes the
    /// saved choice; plain Native (`nil`, or `preset == nil` at `.highest`) removes it.
    private func persistChoice(_ choice: DisplayChoice?, for displayID: String) {
        if let choice, choice.preset != nil || choice.refresh != .highest {
            setChoice(choice, forDisplayID: displayID)
        } else {
            removeChoice(forDisplayID: displayID)
        }
    }

    private func setChoice(_ choice: DisplayChoice, forDisplayID displayID: String) {
        store.setChoice(choice, forDisplayID: displayID)
        savedChoices[displayID] = choice
    }

    private func removeChoice(forDisplayID displayID: String) {
        store.removeChoice(forDisplayID: displayID)
        savedChoices[displayID] = nil
    }

    /// Applies `mode` for the session and starts the countdown; Keep persists `choice` (`nil` is
    /// plain Native) and re-applies permanently. A display that already satisfies `choice` (or
    /// sits on `mode` for Native) only has the intent recorded.
    private func applyNativeMode(_ mode: DisplayModeInfo, choice: DisplayChoice?, description: String,
                                 to display: DisplayInfo) throws {
        recordOriginalModeIfNeeded(for: display)
        let previousModeID = display.currentModeID
        let previousMirror = activeVirtualMirrors[display.id]
        let satisfied = choice.map { isSatisfied(display, by: $0) } ?? (previousModeID == mode.id)
        if previousMirror != nil {
            teardownVirtualMirror(for: display.id)
        } else if satisfied {
            persistChoice(choice, for: display.id)
            Log.display.info("\(display.name) already satisfies \(description); choice recorded")
            return
        }
        Log.display.info("Apply mode \(mode.id) to \(display.name) (session) — previous \(previousModeID ?? -1)")
        try service.apply(modeID: mode.id, to: display.id, persistence: .session)
        refresh()

        let displayID = display.id
        startConfirmation(PendingChange(
            displayID: displayID,
            description: description,
            revert: { [weak self] final in
                guard let self else { return }
                if let previousMirror {
                    // On a final revert the mirror stays down; the saved choice recreates it on
                    // the next launch or wake.
                    if !final, displays.contains(where: { $0.id == displayID }) {
                        Log.virtual.info("Revert: recreating virtual mirror on \(displayID)")
                        try activateVirtualMirror(preset: previousMirror.preset, plan: previousMirror.plan,
                                                  on: previousMirror.physical)
                    }
                } else if let previousModeID {
                    Log.display.info("Revert: mode \(previousModeID) on \(displayID) (session)")
                    try service.apply(modeID: previousModeID, to: displayID, persistence: .session)
                }
                refresh()
            },
            keep: { [weak self] in
                guard let self else { return }
                persistChoice(choice, for: displayID)
                let persistence = try service.applyPreferringPermanent(modeID: mode.id, to: displayID)
                Log.display.info("Keep: mode \(mode.id) on \(displayID) committed \(persistence.rawValue)")
                refresh()
            }))
    }

    /// The virtual-mirror route `select` takes for `.needsVirtualDisplay`: creates the virtual
    /// display, mirrors `display` onto it, and starts the confirmation countdown. Internal so the
    /// live integration suite can drive it on a display whose presets are all natively available.
    func applyVirtualMirror(preset: ResolutionPreset, plan: VirtualDisplayPlan, to display: DisplayInfo) throws {
        guard isVirtualSupported else {
            Log.virtual.notice("Virtual displays unsupported; ignoring \(preset.title) on \(display.name)")
            return
        }
        let wasApplying = isApplying
        isApplying = true
        defer { isApplying = wasApplying }
        let display = physicalView(of: display)
        recordOriginalModeIfNeeded(for: display)
        let previousMirror = activeVirtualMirrors[display.id]
        if previousMirror != nil { teardownVirtualMirror(for: display.id) }
        try activateVirtualMirror(preset: preset, plan: plan, on: display)
        refresh()

        let displayID = display.id
        // The rate preference rides along (a mirror runs at 60 Hz regardless) so it survives a
        // later move back to a native preset.
        let choice = DisplayChoice(preset: preset, scaling: scaling, refresh: savedRefresh(for: displayID))
        startConfirmation(PendingChange(
            displayID: displayID,
            description: ChangeDescription.virtualMirror(display: display, preset: preset, plan: plan),
            revert: { [weak self] final in
                guard let self else { return }
                teardownVirtualMirror(for: displayID)
                if !final, let previousMirror, displays.contains(where: { $0.id == displayID }) {
                    try activateVirtualMirror(preset: previousMirror.preset, plan: previousMirror.plan,
                                              on: previousMirror.physical)
                }
                // No mode is applied: macOS restores the panel's previous mode itself once it
                // has left the mirror set (docs/RESEARCH.md addendum).
                refresh()
            },
            keep: { [weak self] in
                guard let self else { return }
                setChoice(choice, forDisplayID: displayID)
                Log.virtual.info("Keep: virtual mirror \(preset.title) on \(displayID)")
            }))
    }

    /// Creates the virtual display and makes `display` mirror it (virtual = master). On any
    /// failure the virtual display is destroyed before the error propagates.
    private func activateVirtualMirror(preset: ResolutionPreset, plan: VirtualDisplayPlan, on display: DisplayInfo) throws {
        guard let virtualProvider else {
            throw DisplayError.virtualDisplayUnsupported(missingSymbols: [])
        }
        Log.virtual.info("Create virtual display \(plan.pixelSize.description) hiDPI=\(plan.hiDPI) for \(display.name)")
        let virtualID = try virtualProvider.create(name: "ForceRes \(preset.title)", pixelSize: plan.pixelSize,
                                                   hiDPI: plan.hiDPI, physicalDisplayID: display.id)
        do {
            try service.setMirror(physicalDisplayID: display.id, ofVirtualMasterID: virtualID)
        } catch {
            Log.virtual.error("Mirror failed, destroying \(virtualID): \(error.localizedDescription)")
            virtualProvider.destroy(displayID: virtualID)
            throw error
        }
        activeVirtualMirrors[display.id] = ActiveVirtualMirror(virtualID: virtualID, preset: preset, plan: plan,
                                                               physical: display)
        Log.virtual.info("\(display.name) now mirrors virtual \(virtualID)")
    }

    /// Removes the mirror on `physicalID` and destroys its virtual display. No-op when none.
    /// - Parameter holdReconcile: start the reconcile cooldown for the panel (the default); the
    ///   sleep path passes `false` so the wake-up reconcile can recreate the mirror.
    private func teardownVirtualMirror(for physicalID: String, holdReconcile: Bool = true) {
        guard let mirror = activeVirtualMirrors.removeValue(forKey: physicalID) else { return }
        Log.virtual.info("Teardown virtual mirror \(mirror.virtualID) on \(physicalID)")
        retiredVirtualIDs[mirror.virtualID] = RetiredVirtual(retiredAt: now())
        // The panel's mode list stays expanded for several seconds while it leaves the mirror
        // set; hold reconciliation back so no mode id is picked from that list.
        if holdReconcile { lastReconcileApply[physicalID] = now() }
        do {
            try service.removeMirror(physicalDisplayID: physicalID)
        } catch {
            Log.virtual.error("removeMirror(\(physicalID)) failed: \(error.localizedDescription)")
        }
        virtualProvider?.destroy(displayID: mirror.virtualID)
    }

    private func teardownAllVirtualMirrors(holdReconcile: Bool = true) {
        for physicalID in activeVirtualMirrors.keys.sorted() {
            teardownVirtualMirror(for: physicalID, holdReconcile: holdReconcile)
        }
    }

    // MARK: Countdown

    private func startConfirmation(_ change: PendingChange) {
        countdownTask?.cancel()
        pendingConfirmation = change
        secondsRemaining = Self.confirmationSeconds
        Log.display.info("Awaiting confirmation (\(Self.confirmationSeconds) s): \(change.description)")
        countdownTask = Task { [weak self] in
            guard let clock = self?.clock else { return }
            for remaining in stride(from: Self.confirmationSeconds, through: 1, by: -1) {
                self?.secondsRemaining = remaining
                do { try await clock.sleep(for: .seconds(1)) } catch { return }
            }
            guard !Task.isCancelled, let self, pendingConfirmation != nil else { return }
            Log.display.notice("Confirmation timed out; reverting")
            revertPending()
        }
    }

    private func finishCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        pendingConfirmation = nil
        secondsRemaining = 0
    }

    // MARK: Errors

    private func report(_ error: any Error, context: String) {
        Log.display.error("\(context): \(error.localizedDescription)")
        let message = "\(context): \((error as? DisplayError)?.userMessage ?? error.localizedDescription)"
        lastError = message
        presentError?(message)
    }
}
