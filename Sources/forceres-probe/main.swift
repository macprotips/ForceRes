import CoreGraphics
import Foundation
import ForceResCore
import ForceResDisplay

// forceres-probe: read-only display inspection. Never changes display state.
//
//   forceres-probe                   readable table of displays and modes
//   forceres-probe --json            DisplaySnapshot JSON (fixture format)
//   forceres-probe --virtual-support private virtual-display API availability

enum ProbeError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self { case .usage(let s): s }
    }
}

func machineModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func osVersionString() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}

func formatHz(_ hz: Double) -> String {
    hz == hz.rounded() ? String(Int(hz)) : String(format: "%.2f", hz)
}

/// Left-aligned columns; the last cell is not padded.
func row(_ cells: [String], widths: [Int]) -> String {
    var line = "  "
    for (index, cell) in cells.enumerated() {
        if index < widths.count {
            line += cell.padding(toLength: max(widths[index], cell.count + 1), withPad: " ", startingAt: 0)
        } else {
            line += cell
        }
    }
    return line
}

func printTable(_ displays: [DisplayInfo]) {
    if displays.isEmpty { print("No online displays."); return }
    for display in displays {
        let tags = [display.isMain ? "main" : nil, display.isBuiltIn ? "built-in" : nil].compactMap { $0 }
        print("\(display.name)\(tags.isEmpty ? "" : " [\(tags.joined(separator: ", "))]")")
        print("  uuid: \(display.id)")
        print("  native: \(display.nativePixelSize) px   modes: \(display.modes.count) (\(display.modes.filter(\.isUsableForDesktopGUI).count) usable)")
        if let range = display.variableRefreshRange {
            print("  variable refresh: \(formatHz(range.lowerBound))-\(formatHz(range.upperBound)) Hz")
        } else {
            print("  variable refresh: not advertised")
        }
        if let current = display.currentMode {
            print("  current: \(current.pointSize) @ \(formatHz(current.refreshRate)) Hz\(current.isHiDPI ? " HiDPI (\(current.pixelSize) px)" : "")  id=\(current.id)")
        } else {
            print("  current: unknown (id=\(display.currentModeID.map(String.init) ?? "nil"))")
        }
        // Group by point size, largest first; within a group, HiDPI before 1x, then by refresh desc.
        let groups = Dictionary(grouping: display.modes, by: \.pointSize)
        let orderedKeys = groups.keys.sorted { a, b in
            (a.width * a.height, a.width) > (b.width * b.height, b.width)
        }
        let widths = [4, 5, 12, 12, 8, 12]
        print(row(["cur", "id", "points", "pixels", "Hz", "flags", "tags"], widths: widths))
        for key in orderedKeys {
            let modes = (groups[key] ?? []).sorted { a, b in
                if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
                if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
                return a.id < b.id
            }
            for m in modes {
                var tags: [String] = []
                if m.isHiDPI { tags.append("HiDPI") }
                tags.append(m.isUsableForDesktopGUI ? "safe" : "unsafe")
                if m.isNativeTiming { tags.append("native") }
                if m.isInterlaced { tags.append("interlaced") }
                if m.isStretched { tags.append("stretched") }
                if m.isVariableRefresh == true { tags.append("vrr") }
                if m.isProMotion == true { tags.append("promotion") }
                let cells = [m.id == display.currentModeID ? "*" : " ",
                             String(m.id),
                             m.pointSize.description,
                             m.pixelSize.description,
                             formatHz(m.refreshRate),
                             String(format: "0x%08x", m.ioFlags),
                             tags.joined(separator: ",")]
                print(row(cells, widths: widths))
            }
        }
        print("")
    }
}

func printJSON(_ displays: [DisplayInfo]) throws {
    let snapshot = DisplaySnapshot(capturedAt: Date(), machine: machineModel(), osVersion: osVersionString(), displays: displays)
    FileHandle.standardOutput.write(try snapshot.encodedJSON())
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Prints the private-API availability check. Exits 1 when any symbol is missing so scripts can
/// gate on it.
func printVirtualSupport() {
    let (ok, missing) = VirtualDisplayController.isSupported
    print("Private virtual display API (CGVirtualDisplay*): \(ok ? "available" : "UNAVAILABLE")")
    print("Private VRR classifier (SkyLight SLSIsDisplayMode*): \(VariableRefreshClassifier.isAvailable ? "available" : "UNAVAILABLE")\(VariableRefreshClassifier.missingSymbols.isEmpty ? "" : " (missing \(VariableRefreshClassifier.missingSymbols.joined(separator: ", ")))")")
    print("macOS \(osVersionString()) on \(machineModel())")
    if missing.isEmpty {
        print("All required classes and selectors resolve via NSClassFromString / respondsToSelector.")
    } else {
        print("Missing symbols:")
        for symbol in missing { print("  - \(symbol)") }
    }
    if !ok { exit(1) }
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    let service = CoreGraphicsDisplayService()
    switch args {
    case []:
        printTable(try service.snapshot())
    case ["--json"]:
        try printJSON(try service.snapshot())
    case ["--virtual-support"]:
        printVirtualSupport()
    case ["--help"], ["-h"]:
        print("usage: forceres-probe [--json | --virtual-support]")
    default:
        throw ProbeError.usage("unknown arguments: \(args.joined(separator: " ")). usage: forceres-probe [--json | --virtual-support]")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("forceres-probe: \(error)\n".utf8))
    exit(1)
}
