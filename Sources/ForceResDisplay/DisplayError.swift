import CoreGraphics
import Foundation

/// Every failure the display layer can report. All CoreGraphics `CGError` values are mapped here
/// so callers never see a raw error code.
public enum DisplayError: Error, Sendable, Equatable {
    /// The UUID string could not be parsed as a CFUUID.
    case invalidDisplayUUID(String)
    /// No online display currently carries that UUID (unplugged, asleep, or never existed).
    case displayNotFound(String)
    /// The display exists but does not enumerate a mode with that `ioDisplayModeID`.
    case modeNotFound(modeID: Int32, displayID: String)
    /// The mode lacks the IOKit safe flag (`0x2`); ForceRes never applies such modes.
    case unsafeMode(modeID: Int32)
    /// A CoreGraphics configuration call failed.
    /// - Parameters:
    ///   - stage: which call failed (`begin`, `configure`, `mirror`, `complete`).
    ///   - code: the raw `CGError.rawValue`.
    ///   - fullScreenAppBlocking: `true` when the error is the one CoreGraphics returns while
    ///     another app runs in full-screen mode; surface a hint to the user.
    case configurationFailed(stage: ConfigurationStage, code: Int32, fullScreenAppBlocking: Bool)
    /// A mirror request would make a virtual display the mirror target, or the master is not a
    /// virtual display created by `VirtualDisplayController`. Both directions crash WindowServer.
    case unsafeMirrorDirection(master: String, mirror: String)
    /// The requested mirror target is not backed by real hardware (no built-in flag and no
    /// matching IORegistry framebuffer), so it may be someone else's virtual display.
    case notAPhysicalDisplay(String)
    /// The private `CGVirtualDisplay` classes/selectors did not all resolve at runtime.
    case virtualDisplayUnsupported(missingSymbols: [String])
    /// The bundled `forceres-vdhost` executable is missing or not executable.
    case helperMissing
    /// `CGVirtualDisplay` creation returned nil or `applySettings:` returned NO.
    case virtualDisplayCreationFailed(String)
    /// The virtual display never appeared in `CGGetOnlineDisplayList` within the timeout.
    case virtualDisplayTimedOut(seconds: Double)

    /// Which call inside a `CGBeginDisplayConfiguration` transaction failed.
    public enum ConfigurationStage: String, Sendable {
        case begin, configure, mirror, complete
    }
}

extension DisplayError: LocalizedError {
    /// Plain-English text for the user. `errorDescription` stays technical, for the log.
    public var userMessage: String {
        switch self {
        case .configurationFailed(_, _, let fullScreenAppBlocking):
            return fullScreenAppBlocking
                ? "macOS would not change the display. Quit any app running full screen and try again."
                : "macOS would not change the display. Try again in a moment."
        case .unsafeMode:
            return "This display does not support that resolution."
        case .displayNotFound, .invalidDisplayUUID:
            return "That display is no longer connected."
        case .modeNotFound:
            return "That resolution is no longer available on this display."
        case .helperMissing:
            return "ForceRes is missing part of its installation. Reinstall the app."
        case .virtualDisplayUnsupported:
            return "This version of macOS does not allow the display ForceRes needs for that size."
        case .virtualDisplayCreationFailed, .virtualDisplayTimedOut:
            return "ForceRes could not set up the display it needs for that size."
        case .notAPhysicalDisplay, .unsafeMirrorDirection:
            return "ForceRes can only change a display attached to this Mac."
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidDisplayUUID(let s):
            return "\"\(s)\" is not a valid display UUID."
        case .displayNotFound(let s):
            return "No connected display has the identifier \(s)."
        case .modeNotFound(let modeID, let displayID):
            return "Display \(displayID) has no mode with id \(modeID)."
        case .unsafeMode(let modeID):
            return "Mode \(modeID) is not flagged safe by the display driver and cannot be applied."
        case .configurationFailed(let stage, let code, let fullScreen):
            var text = "Display configuration failed during \(stage.rawValue): \(Self.describe(code: code)) (CGError \(code))."
            if fullScreen {
                text += " A full-screen app may be blocking display changes; leave full screen and try again."
            }
            return text
        case .unsafeMirrorDirection(let master, let mirror):
            return "Refusing mirror \(mirror) → \(master): only a physical display may mirror a ForceRes virtual display."
        case .notAPhysicalDisplay(let s):
            return "Display \(s) is not a physical display; only physical displays can mirror a ForceRes virtual display."
        case .virtualDisplayUnsupported(let missing):
            return "Virtual displays are unavailable on this macOS: missing \(missing.joined(separator: ", "))."
        case .helperMissing:
            return "ForceRes is missing its display helper; reinstall the app."
        case .virtualDisplayCreationFailed(let reason):
            return "Could not create the virtual display: \(reason)"
        case .virtualDisplayTimedOut(let seconds):
            return "The virtual display did not come online within \(seconds) s."
        }
    }

    /// Readable name for a `CGError` raw value (CGError.h).
    static func describe(code: Int32) -> String {
        switch CGError(rawValue: code) {
        case .success: "success"
        case .failure: "generic failure"
        case .illegalArgument: "illegal argument"
        case .invalidConnection: "invalid connection to the window server"
        case .invalidContext: "invalid context"
        case .cannotComplete: "the operation cannot complete"
        case .notImplemented: "not implemented"
        case .rangeCheck: "range check failed"
        case .typeCheck: "type check failed"
        case .invalidOperation: "invalid operation"
        case .noneAvailable: "no resources available"
        default: "unknown error"
        }
    }

    /// Builds `.configurationFailed` from a `CGError`, flagging the full-screen-app case.
    /// CoreGraphics reports a blocking full-screen app as `kCGErrorFailure`/`cannotComplete` on the
    /// completing call; the header only promises "may fail", so the flag is a hint, not proof.
    static func configuration(_ stage: ConfigurationStage, _ error: CGError) -> DisplayError {
        let fullScreen = stage == .complete && (error == .failure || error == .cannotComplete)
        return .configurationFailed(stage: stage, code: error.rawValue, fullScreenAppBlocking: fullScreen)
    }
}
