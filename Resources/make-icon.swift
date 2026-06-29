#!/usr/bin/env swift
// Generates an .iconset directory with every size macOS expects for iconutil.
//
// House style shared with the sibling apps (~/src/uncommitted, ~/src/upcoming):
// Apple Big Sur+ template geometry, a pink→purple→blue gradient, a magenta
// hotspot, a top-edge highlight, and a drop shadow living in the 100px gutter.
// The glyph is the Spotify mark — its three arcs only (Resources/spotify-glyph.svg,
// traced from the official logo), in white, with no green disc behind them.
//
//   Canvas:         1024×1024
//   Icon body:      824×824 centered (100px gutter all sides)
//   Corner radius:  ~232 circular ≈ Apple's 185.4 continuous squircle
//   Drop shadow:    28px blur, 12px down, black 50%
//
// Usage: swift Resources/make-icon.swift <output.iconset>

import Foundation
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("Usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}

let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// The white glyph, rendered once at high resolution and tightly cropped to its
// alpha bounds so it fills the glyph rect regardless of the SVG's own padding.
struct Glyph { let image: CGImage; let aspect: CGFloat }

func loadGlyph() -> Glyph? {
    let url = URL(fileURLWithPath: "Resources/spotify-glyph.svg")
    guard let svg = NSImage(contentsOf: url) else { return nil }

    let S = 1024
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    svg.draw(in: NSRect(x: 0, y: 0, width: S, height: S), from: .zero,
             operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let full = rep.cgImage, let data = rep.bitmapData else { return nil }
    let bpp = rep.bitsPerPixel / 8
    let rowBytes = rep.bytesPerRow

    // Alpha bounding box (rep rows are top-down, matching CGImage cropping).
    var minX = S, minY = S, maxX = -1, maxY = -1
    for y in 0..<S {
        for x in 0..<S where data[y * rowBytes + x * bpp + (bpp - 1)] > 10 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }

    let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    guard let cropped = full.cropping(to: crop) else { return nil }
    return Glyph(image: cropped, aspect: crop.width / crop.height)
}

guard let glyph = loadGlyph() else {
    FileHandle.standardError.write("Could not load Resources/spotify-glyph.svg\n".data(using: .utf8)!)
    exit(1)
}

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    // Apple template geometry: 824×824 body inside a 1024×1024 canvas, with a
    // 100px gutter on every side that hosts the drop shadow.
    let gutter = size * (100.0 / 1024.0)
    let inner = size - gutter * 2
    let rect = CGRect(x: gutter, y: gutter, width: inner, height: inner)
    let cornerRadius = inner * (232.0 / 824.0)
    let bodyPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius, transform: nil)

    // Body drop shadow, cast from an opaque fill the gradient paints over.
    let shadowScale = size / 1024.0
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * shadowScale),
                  blur: 28 * shadowScale,
                  color: NSColor.black.withAlphaComponent(0.5).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // Pink → purple → blue-violet gradient, top-left → bottom-right.
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.878, green: 0.000, blue: 0.565, alpha: 1).cgColor, // #E00090
        NSColor(srgbRed: 0.537, green: 0.000, blue: 0.824, alpha: 1).cgColor, // #8900D2
        NSColor(srgbRed: 0.310, green: 0.000, blue: 1.000, alpha: 1).cgColor, // #4F00FF
    ] as CFArray, locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Magenta radial hotspot in the upper-left, screen-blended for luminance.
    let hotspot = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 1.0, green: 0.10, blue: 0.70, alpha: 0.70).cgColor,
        NSColor(srgbRed: 1.0, green: 0.10, blue: 0.70, alpha: 0.00).cgColor,
    ] as CFArray, locations: [0, 1])!
    let hotspotCenter = CGPoint(x: rect.minX + inner * 0.25, y: rect.minY + inner * 0.82)
    ctx.saveGState()
    ctx.setBlendMode(.screen)
    ctx.drawRadialGradient(hotspot, startCenter: hotspotCenter, startRadius: 0,
                           endCenter: hotspotCenter, endRadius: inner * 0.7, options: [])
    ctx.restoreGState()

    // Subtle top-edge highlight for depth.
    let highlight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.18).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(highlight, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY + inner * 0.55), options: [])
    ctx.restoreGState() // body clip

    // ---- Spotify mark (three white bars), centered with a soft drop shadow ----
    let maxDim = inner * 0.62
    let glyphSize = glyph.aspect >= 1
        ? NSSize(width: maxDim, height: maxDim / glyph.aspect)
        : NSSize(width: maxDim * glyph.aspect, height: maxDim)
    let glyphRect = CGRect(x: rect.midX - glyphSize.width / 2,
                           y: rect.midY - glyphSize.height / 2,
                           width: glyphSize.width, height: glyphSize.height)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.04,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.draw(glyph.image, in: glyphRect)
    ctx.restoreGState()

    return image
}

func writePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 2)
    }
    try png.write(to: url)
}

struct IconEntry {
    let base: Int
    let scale: Int
    var filename: String {
        scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@\(scale)x.png"
    }
    var pixelSize: Int { base * scale }
}

let entries: [IconEntry] = [
    .init(base: 16, scale: 1),  .init(base: 16, scale: 2),
    .init(base: 32, scale: 1),  .init(base: 32, scale: 2),
    .init(base: 128, scale: 1), .init(base: 128, scale: 2),
    .init(base: 256, scale: 1), .init(base: 256, scale: 2),
    .init(base: 512, scale: 1), .init(base: 512, scale: 2),
]

for entry in entries {
    let image = render(size: CGFloat(entry.pixelSize))
    try writePNG(image, to: outDir.appendingPathComponent(entry.filename), pixelSize: entry.pixelSize)
    print("wrote \(entry.filename)")
}
