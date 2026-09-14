import CoreGraphics
import Foundation

var count: UInt32 = 0
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
CGGetOnlineDisplayList(16, &ids, &count)
for i in 0..<Int(count) {
    let d = ids[i]
    print("Display \(d) main=\(CGDisplayIsMain(d)) builtin=\(CGDisplayIsBuiltin(d)) pixels=\(CGDisplayPixelsWide(d))x\(CGDisplayPixelsHigh(d))")
    if let cur = CGDisplayCopyDisplayMode(d) {
        print(" current: \(cur.width)x\(cur.height) px=\(cur.pixelWidth)x\(cur.pixelHeight) \(cur.refreshRate)Hz gui=\(cur.isUsableForDesktopGUI()) flags=\(cur.ioFlags)")
    }
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    let modes = CGDisplayCopyAllDisplayModes(d, opts) as! [CGDisplayMode]
    print(" \(modes.count) modes (with duplicates flag):")
    for m in modes {
        let hidpi = m.pixelWidth != m.width
        print("  \(m.width)x\(m.height)\(hidpi ? " HiDPI(px \(m.pixelWidth)x\(m.pixelHeight))" : "") @\(m.refreshRate)Hz gui=\(m.isUsableForDesktopGUI()) flags=0x\(String(m.ioFlags, radix:16)) id=\(m.ioDisplayModeID)")
    }
}
