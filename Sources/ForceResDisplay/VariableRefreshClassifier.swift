import CoreGraphics
import Foundation
import ForceResCore

/// Tells the variable-refresh twin of a duplicate mode pair from its fixed twin.
///
/// Nothing public distinguishes them (docs/RESEARCH.md section 11), so this resolves SkyLight's
/// private `SLSIsDisplayModeVRR` and `SLSIsDisplayModeProMotion` (`bool (CGDirectDisplayID,
/// int32_t modeID)`) with `dlopen`/`dlsym` at first use. Nothing is linked: `nm -u` on every
/// binary must stay free of `SLSIsDisplayMode*`. When a symbol is missing every answer is `nil`
/// and the selector treats all modes as unclassified.
public enum VariableRefreshClassifier: Sendable {
    private typealias ModeQuery = @convention(c) (CGDirectDisplayID, Int32) -> Bool

    private struct Symbols: Sendable {
        var isVRR: ModeQuery?
        var isProMotion: ModeQuery?
    }

    /// Resolved once per process; the handle is deliberately never closed.
    private static let symbols: Symbols = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return Symbols()
        }
        func load(_ name: String) -> ModeQuery? {
            guard let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: ModeQuery.self)
        }
        return Symbols(isVRR: load("SLSIsDisplayModeVRR"), isProMotion: load("SLSIsDisplayModeProMotion"))
    }()

    /// `true` when `SLSIsDisplayModeVRR` resolved on this macOS.
    public static var isAvailable: Bool { symbols.isVRR != nil }

    /// Names of the private functions that failed to resolve (empty when everything is available).
    public static var missingSymbols: [String] {
        var missing: [String] = []
        if symbols.isVRR == nil { missing.append("SLSIsDisplayModeVRR") }
        if symbols.isProMotion == nil { missing.append("SLSIsDisplayModeProMotion") }
        return missing
    }

    /// Whether mode `modeID` of `displayID` is a variable-refresh entry; `nil` when unavailable.
    public static func isVariableRefresh(displayID: CGDirectDisplayID, modeID: Int32) -> Bool? {
        symbols.isVRR.map { $0(displayID, modeID) }
    }

    /// Whether mode `modeID` of `displayID` is a ProMotion entry; `nil` when unavailable.
    public static func isProMotion(displayID: CGDirectDisplayID, modeID: Int32) -> Bool? {
        symbols.isProMotion.map { $0(displayID, modeID) }
    }

    /// `mode` with `isVariableRefresh` and `isProMotion` filled in for `displayID`.
    static func classify(_ mode: DisplayModeInfo, displayID: CGDirectDisplayID) -> DisplayModeInfo {
        var mode = mode
        mode.isVariableRefresh = isVariableRefresh(displayID: displayID, modeID: mode.id)
        mode.isProMotion = isProMotion(displayID: displayID, modeID: mode.id)
        return mode
    }
}
