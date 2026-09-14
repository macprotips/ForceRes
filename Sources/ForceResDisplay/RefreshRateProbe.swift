import AppKit
import CoreGraphics
import Foundation

/// Public confirmation of the refresh state actually in effect on a display, from `NSScreen`.
///
/// Only the *active* mode can be read this way (docs/RESEARCH.md section 11): a screen whose
/// `displayUpdateGranularity` is 0 while `minimumRefreshInterval != maximumRefreshInterval` is
/// running variable refresh. `NSScreen` is main-thread only, hence `@MainActor`.
public enum RefreshRateProbe: Sendable {
    /// The active refresh state of `displayID`, or `nil` when no `NSScreen` carries that id.
    /// `maxFPS` is `NSScreen.maximumFramesPerSecond`.
    @MainActor
    public static func activeRefresh(for displayID: CGDirectDisplayID) -> (maxFPS: Int, isVariable: Bool)? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }) else { return nil }
        let variable = screen.displayUpdateGranularity == 0
            && screen.minimumRefreshInterval != screen.maximumRefreshInterval
        return (screen.maximumFramesPerSecond, variable)
    }
}
