#!/usr/bin/env swift

// Renders every app icon slot from one drawing: a reader with three lines of
// text and an amber bookmark. iOS slots are opaque squares, as App Store
// Connect requires. macOS slots follow the Big Sur-and-later template: the
// rounded-rectangle shape inset from a transparent 1024 canvas, so the Dock
// shows the same silhouette as every other app. Slots at 64 px and below use
// a simplified drawing with thicker strokes that still reads at 16 px.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconSlot {
    let filename: String
    let pixels: Int
    let mac: Bool
}

let slots = [
    IconSlot(filename: "icon-20@2x.png", pixels: 40, mac: false),
    IconSlot(filename: "icon-20@3x.png", pixels: 60, mac: false),
    IconSlot(filename: "icon-29@2x.png", pixels: 58, mac: false),
    IconSlot(filename: "icon-29@3x.png", pixels: 87, mac: false),
    IconSlot(filename: "icon-40@2x.png", pixels: 80, mac: false),
    IconSlot(filename: "icon-40@3x.png", pixels: 120, mac: false),
    IconSlot(filename: "icon-60@2x.png", pixels: 120, mac: false),
    IconSlot(filename: "icon-60@3x.png", pixels: 180, mac: false),
    IconSlot(filename: "icon-76.png", pixels: 76, mac: false),
    IconSlot(filename: "icon-76@2x.png", pixels: 152, mac: false),
    IconSlot(filename: "icon-83.5@2x.png", pixels: 167, mac: false),
    IconSlot(filename: "icon-1024.png", pixels: 1024, mac: false),
    IconSlot(filename: "icon-mac-16.png", pixels: 16, mac: true),
    IconSlot(filename: "icon-mac-16@2x.png", pixels: 32, mac: true),
    IconSlot(filename: "icon-mac-32.png", pixels: 32, mac: true),
    IconSlot(filename: "icon-mac-32@2x.png", pixels: 64, mac: true),
    IconSlot(filename: "icon-mac-128.png", pixels: 128, mac: true),
    IconSlot(filename: "icon-mac-128@2x.png", pixels: 256, mac: true),
    IconSlot(filename: "icon-mac-256.png", pixels: 256, mac: true),
    IconSlot(filename: "icon-mac-256@2x.png", pixels: 512, mac: true),
    IconSlot(filename: "icon-mac-512.png", pixels: 512, mac: true),
    IconSlot(filename: "icon-mac-512@2x.png", pixels: 1024, mac: true),
]

let background: UInt32 = 0xEFE8D6
let chassis: UInt32 = 0x1B1F1D
let screen: UInt32 = 0xFCFAF4
let amber: UInt32 = 0xC7771E

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

func roundedRect(_ rect: CGRect, radius: CGFloat, fill: CGColor, context: CGContext) {
    context.setFillColor(fill)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}

/// The reader, drawn in a 1024-point square. `detail` is false for small
/// slots: fewer, thicker marks so the drawing survives 16 and 32 px.
func drawReader(in context: CGContext, detail: Bool) {
    context.setFillColor(color(background))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    roundedRect(CGRect(x: 184, y: 72, width: 656, height: 880), radius: 154, fill: color(chassis), context: context)
    roundedRect(CGRect(x: 258, y: 254, width: 508, height: 604), radius: 54, fill: color(screen), context: context)

    if detail {
        roundedRect(CGRect(x: 330, y: 704, width: 364, height: 46), radius: 23, fill: color(chassis), context: context)
        roundedRect(CGRect(x: 330, y: 604, width: 260, height: 46), radius: 23, fill: color(chassis), context: context)
        roundedRect(CGRect(x: 330, y: 504, width: 324, height: 46), radius: 23, fill: color(chassis), context: context)
        context.setFillColor(color(amber))
        context.fillEllipse(in: CGRect(x: 319, y: 341, width: 58, height: 58))
        roundedRect(CGRect(x: 396, y: 347, width: 226, height: 46), radius: 23, fill: color(amber), context: context)
        roundedRect(CGRect(x: 394, y: 148, width: 236, height: 34), radius: 17, fill: color(amber), context: context)
    } else {
        roundedRect(CGRect(x: 330, y: 680, width: 364, height: 72), radius: 36, fill: color(chassis), context: context)
        roundedRect(CGRect(x: 330, y: 540, width: 280, height: 72), radius: 36, fill: color(chassis), context: context)
        roundedRect(CGRect(x: 330, y: 360, width: 300, height: 72), radius: 36, fill: color(amber), context: context)
        roundedRect(CGRect(x: 394, y: 140, width: 236, height: 52), radius: 26, fill: color(amber), context: context)
    }
}

func render(slot: IconSlot, destination: URL) throws {
    let size = slot.pixels
    let scale = CGFloat(size) / 1024
    let alpha: CGImageAlphaInfo = slot.mac ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: alpha.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.scaleBy(x: scale, y: scale)
    let detail = size > 64

    if slot.mac {
        // Apple's macOS icon grid: the shape occupies 824 of 1024 points, with a
        // corner radius of about 22.4% of its side, and the rest stays transparent.
        let shape = CGRect(x: 100, y: 100, width: 824, height: 824)
        context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        context.saveGState()
        context.addPath(CGPath(roundedRect: shape, cornerWidth: 184.5, cornerHeight: 184.5, transform: nil))
        context.clip()
        context.translateBy(x: shape.minX, y: shape.minY)
        context.scaleBy(x: shape.width / 1024, y: shape.height / 1024)
        drawReader(in: context, detail: detail)
        context.restoreGState()
    } else {
        drawReader(in: context, detail: detail)
    }

    guard let image = context.makeImage(),
          let writer = CGImageDestinationCreateWithURL(
              destination as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for slot in slots {
    try render(slot: slot, destination: output.appendingPathComponent(slot.filename))
}
print("Generated \(slots.count) Pocket Daily app icons in \(output.path)")
