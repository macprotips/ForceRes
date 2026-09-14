#!/usr/bin/env swift
//
// make-icon.swift
//
// Renders the ForceRes app icon from code (no external assets) at every size
// iconutil needs, into Resources/icon-build/AppIcon.iconset. Run via
// Scripts/make-icon.sh, which also invokes `iconutil` to produce the .icns.
//
// Design: a rounded-square blue-to-teal gradient behind a monitor glyph, so the
// icon reads as "a display" at a glance.

import AppKit
import CoreGraphics
import Foundation

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/icon-build/AppIcon.iconset")

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> CGImage? {
    let size = CGFloat(pixels)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // macOS "squircle" corner radius convention is roughly 22.5% of the edge.
    let cornerRadius = size * 0.225
    let backgroundPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(backgroundPath)
    ctx.clip()

    // Deep blue -> teal diagonal gradient background.
    let colors = [
        CGColor(red: 0.09, green: 0.13, blue: 0.28, alpha: 1.0),
        CGColor(red: 0.06, green: 0.44, blue: 0.53, alpha: 1.0),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: size, y: 0),
            options: []
        )
    }
    ctx.restoreGState()

    // Monitor glyph: rounded-rect screen with a small stand/base, centered.
    let glyphWidth = size * 0.62
    let glyphHeight = glyphWidth * 0.66
    let screenRect = CGRect(
        x: (size - glyphWidth) / 2,
        y: size * 0.40,
        width: glyphWidth,
        height: glyphHeight
    )
    let screenRadius = glyphWidth * 0.09
    let screenPath = CGPath(roundedRect: screenRect, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil)

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.addPath(screenPath)
    ctx.fillPath()

    // Screen "content": a smaller inset rect in the gradient's dark color, so
    // the glyph reads as a display rather than a solid card.
    let insetInsetAmount = glyphWidth * 0.07
    let innerRect = screenRect.insetBy(dx: insetInsetAmount, dy: insetInsetAmount)
    ctx.setFillColor(CGColor(red: 0.09, green: 0.13, blue: 0.28, alpha: 1.0))
    ctx.addPath(CGPath(roundedRect: innerRect, cornerWidth: screenRadius * 0.6, cornerHeight: screenRadius * 0.6, transform: nil))
    ctx.fillPath()

    // Stand: a small trapezoid-ish neck plus a base bar beneath the screen.
    let neckWidth = glyphWidth * 0.16
    let neckHeight = glyphHeight * 0.22
    let neckRect = CGRect(
        x: (size - neckWidth) / 2,
        y: screenRect.minY - neckHeight,
        width: neckWidth,
        height: neckHeight
    )
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.fill(neckRect)

    let baseWidth = glyphWidth * 0.5
    let baseHeight = glyphHeight * 0.09
    let baseRect = CGRect(
        x: (size - baseWidth) / 2,
        y: neckRect.minY - baseHeight,
        width: baseWidth,
        height: baseHeight
    )
    let basePath = CGPath(roundedRect: baseRect, cornerWidth: baseHeight * 0.5, cornerHeight: baseHeight * 0.5, transform: nil)
    ctx.addPath(basePath)
    ctx.fillPath()

    return ctx.makeImage()
}

for (name, pixels) in sizes {
    guard let image = drawIcon(pixels: pixels) else {
        FileHandle.standardError.write("make-icon.swift: failed to render \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("make-icon.swift: failed to encode \(name) as PNG\n".data(using: .utf8)!)
        exit(1)
    }
    let fileURL = outputDir.appendingPathComponent("\(name).png")
    do {
        try data.write(to: fileURL)
        print("wrote \(fileURL.path)")
    } catch {
        FileHandle.standardError.write("make-icon.swift: failed to write \(fileURL.path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
