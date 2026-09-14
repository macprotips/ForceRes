import Foundation
import ForceResCore

/// Loads recorded `DisplaySnapshot` JSON documents from `Fixtures/`.
enum FixtureLoader {
    enum Fixture: String {
        /// Real dump: Mac mini (M4) driving a Samsung Odyssey G80SD, 242 modes.
        case m4OdysseyG80SD = "m4-mac-mini-odyssey-g80sd"
        /// Synthetic 16-mode M1 MacBook Air built-in panel (docs/RESEARCH.md section 2).
        case m1MacBookAir = "m1-macbook-air-builtin"
        /// Synthetic 1080p-native external monitor with no HiDPI 1080p variant.
        case external1080p = "external-1080p-60hz"
    }

    enum Error: Swift.Error {
        case missing(String)
        case noDisplays(String)
    }

    static func snapshot(_ fixture: Fixture) throws -> DisplaySnapshot {
        guard let url = Bundle.module.url(forResource: fixture.rawValue, withExtension: "json",
                                          subdirectory: "Fixtures") else {
            throw Error.missing(fixture.rawValue)
        }
        return try DisplaySnapshot.decode(from: Data(contentsOf: url))
    }

    /// The single display each fixture records.
    static func display(_ fixture: Fixture) throws -> DisplayInfo {
        guard let display = try snapshot(fixture).displays.first else {
            throw Error.noDisplays(fixture.rawValue)
        }
        return display
    }

    /// `display` with every unclassified mode (`isVariableRefresh == nil`) recorded as fixed, the
    /// shape a dump with the SkyLight classifier available has. Fixture-independent: tests that
    /// assert `.exact`/`.fellBackToHighest` outcomes use it so a partially classified fixture does
    /// not turn them into `.unverified`.
    static func classified(_ display: DisplayInfo) -> DisplayInfo {
        var display = display
        display.modes = display.modes.map { mode in
            var mode = mode
            if mode.isVariableRefresh == nil { mode.isVariableRefresh = false }
            return mode
        }
        return display
    }
}

/// Convenience for building synthetic modes in tests.
func mode(id: Int32, _ width: Int, _ height: Int, hiDPI: Bool = false, hz: Double = 60,
          flags: UInt32 = DisplayModeInfo.IOFlags.valid | DisplayModeInfo.IOFlags.safe,
          gui: Bool = true) -> DisplayModeInfo {
    DisplayModeInfo(id: id, width: width, height: height,
                    pixelWidth: hiDPI ? width * 2 : width, pixelHeight: hiDPI ? height * 2 : height,
                    refreshRate: hz, ioFlags: flags, isUsableForDesktopGUI: gui)
}

func display(named name: String = "Test", builtIn: Bool = false, native: PixelSize? = nil,
             modes: [DisplayModeInfo], current: Int32? = nil) -> DisplayInfo {
    DisplayInfo(id: "00000000-0000-0000-0000-000000000001", name: name, isBuiltIn: builtIn, isMain: true,
                nativePixelSize: native ?? ModeSelector.nativePixelSize(from: modes),
                modes: modes, currentModeID: current)
}
