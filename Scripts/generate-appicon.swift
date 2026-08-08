#!/usr/bin/env swift
//
// Draws Atmosphere's app icon and writes Atmosphere/Resources/AppIcon.icns.
//
//   swift Scripts/generate-appicon.swift
//
// The icon is the in-app mark at Dock scale: a pixel-art crescent moon and a
// few pixel stars on flat night sky. Same 13x13 grid the app draws, same flat
// colours, no gradients — every size is rendered natively from the grid rather
// than downsampled from one big bitmap.

import AppKit
import Foundation

// MARK: - Palette

private func srgb(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat(red) / 255,
        green: CGFloat(green) / 255,
        blue: CGFloat(blue) / 255,
        alpha: alpha
    )
}

private let sky = srgb(17, 21, 46)
private let moonColor = srgb(245, 247, 255)
private let starColor = srgb(226, 231, 250)

// MARK: - Pixel grid

private let grid = 13

private func moonCells() -> [(x: Int, y: Int)] {
    var cells: [(x: Int, y: Int)] = []
    for row in 0..<grid {
        for column in 0..<grid {
            let x = CGFloat(column) + 0.5
            // The icon's y runs upward; the app's runs downward. Flipping here
            // keeps one set of coordinates for both.
            let y = CGFloat(grid - 1 - row) + 0.5
            let inDisc = hypot(x - 6.5, y - 6.5) <= 5.8
            let inBite = hypot(x - 9.9, y - 6.5) <= 5.6
            if inDisc && !inBite {
                cells.append((column, row))
            }
        }
    }
    return cells
}

/// A five-cell plus, at its own scale, dropped anywhere on the plate.
private let starCells: [(x: Int, y: Int)] = [(1, 0), (0, 1), (1, 1), (2, 1), (1, 2)]

// MARK: - Drawing

private func drawIcon(in context: CGContext, side: CGFloat) {
    let scale = side / 1024

    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(false)

    // macOS icons sit on an inset squircle rather than filling the canvas.
    let inset: CGFloat = 100
    let plate = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let platePath = CGPath(
        roundedRect: plate,
        cornerWidth: 190,
        cornerHeight: 190,
        transform: nil
    )

    context.saveGState()
    context.setShouldAntialias(true)
    context.addPath(platePath)
    context.setFillColor(sky)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    context.setShouldAntialias(false)

    // The moon, on the same grid the app uses.
    let cell = (plate.width * 0.62 / CGFloat(grid)).rounded()
    let moonSide = cell * CGFloat(grid)
    let moonOrigin = CGPoint(
        x: (plate.midX - moonSide / 2 + cell * 0.6).rounded(),
        y: (plate.midY - moonSide / 2).rounded()
    )
    context.setFillColor(moonColor)
    for pixel in moonCells() {
        context.fill(
            CGRect(
                x: moonOrigin.x + CGFloat(pixel.x) * cell,
                y: moonOrigin.y + CGFloat(pixel.y) * cell,
                width: cell,
                height: cell
            )
        )
    }

    // Stars, scattered clear of the moon.
    let stars: [(x: CGFloat, y: CGFloat, scale: CGFloat, alpha: CGFloat)] = [
        (0.14, 0.78, 1.0, 1.0),
        (0.15, 0.24, 0.72, 0.8),
        (0.07, 0.50, 0.6, 0.62),
        (0.83, 0.18, 0.8, 0.72),
        (0.60, 0.88, 0.62, 0.6),
        (0.87, 0.58, 0.55, 0.5)
    ]
    for star in stars {
        let starCell = (cell * 0.62 * star.scale).rounded()
        guard starCell >= 1 else { continue }
        let origin = CGPoint(
            x: (plate.minX + plate.width * star.x).rounded(),
            y: (plate.minY + plate.height * star.y).rounded()
        )
        context.setFillColor(starColor.copy(alpha: star.alpha) ?? starColor)
        for pixel in starCells {
            context.fill(
                CGRect(
                    x: origin.x + CGFloat(pixel.x) * starCell,
                    y: origin.y + CGFloat(pixel.y) * starCell,
                    width: starCell,
                    height: starCell
                )
            )
        }
    }

    context.restoreGState()
    context.restoreGState()
}

// MARK: - Output

private func renderPNG(side: Int) -> Data? {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: side,
        pixelsHigh: side,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.interpolationQuality = .high
    context.cgContext.setAllowsAntialiasing(true)
    drawIcon(in: context.cgContext, side: CGFloat(side))
    NSGraphicsContext.restoreGraphicsState()

    return representation.representation(using: .png, properties: [:])
}

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetURL = projectRoot.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
let resourcesURL = projectRoot.appendingPathComponent("Atmosphere/Resources", isDirectory: true)

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

let variants: [(name: String, side: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    guard let data = renderPNG(side: variant.side) else {
        FileHandle.standardError.write(Data("Failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconsetURL.appendingPathComponent("\(variant.name).png"))
}

// A standalone 1024 preview, handy for README and store-style shots.
if let data = renderPNG(side: 1024) {
    try data.write(to: projectRoot.appendingPathComponent("Artwork/appicon-1024.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "--convert", "icns",
    iconsetURL.path,
    "--output", resourcesURL.appendingPathComponent("AppIcon.icns").path
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

print("Wrote Atmosphere/Resources/AppIcon.icns")
