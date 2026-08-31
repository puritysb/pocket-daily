#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconSlot {
    let filename: String
    let pixels: Int
}

let slots = [
    IconSlot(filename: "icon-20@2x.png", pixels: 40),
    IconSlot(filename: "icon-20@3x.png", pixels: 60),
    IconSlot(filename: "icon-29@2x.png", pixels: 58),
    IconSlot(filename: "icon-29@3x.png", pixels: 87),
    IconSlot(filename: "icon-40@2x.png", pixels: 80),
    IconSlot(filename: "icon-40@3x.png", pixels: 120),
    IconSlot(filename: "icon-60@2x.png", pixels: 120),
    IconSlot(filename: "icon-60@3x.png", pixels: 180),
    IconSlot(filename: "icon-76.png", pixels: 76),
    IconSlot(filename: "icon-76@2x.png", pixels: 152),
    IconSlot(filename: "icon-83.5@2x.png", pixels: 167),
    IconSlot(filename: "icon-1024.png", pixels: 1024),
    IconSlot(filename: "icon-mac-16.png", pixels: 16),
    IconSlot(filename: "icon-mac-16@2x.png", pixels: 32),
    IconSlot(filename: "icon-mac-32.png", pixels: 32),
    IconSlot(filename: "icon-mac-32@2x.png", pixels: 64),
    IconSlot(filename: "icon-mac-128.png", pixels: 128),
    IconSlot(filename: "icon-mac-128@2x.png", pixels: 256),
    IconSlot(filename: "icon-mac-256.png", pixels: 256),
    IconSlot(filename: "icon-mac-256@2x.png", pixels: 512),
    IconSlot(filename: "icon-mac-512.png", pixels: 512),
    IconSlot(filename: "icon-mac-512@2x.png", pixels: 1024),
]

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

func render(size: Int, destination: URL) throws {
    let scale = CGFloat(size) / 1024
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(color(0xF3EEDF))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    roundedRect(CGRect(x: 184, y: 72, width: 656, height: 880), radius: 154, fill: color(0x1B1F1D), context: context)
    roundedRect(CGRect(x: 258, y: 254, width: 508, height: 604), radius: 54, fill: color(0xF4F0E5), context: context)
    roundedRect(CGRect(x: 330, y: 704, width: 364, height: 46), radius: 23, fill: color(0x1B1F1D), context: context)
    roundedRect(CGRect(x: 330, y: 604, width: 260, height: 46), radius: 23, fill: color(0x1B1F1D), context: context)
    roundedRect(CGRect(x: 330, y: 504, width: 324, height: 46), radius: 23, fill: color(0x1B1F1D), context: context)
    context.setFillColor(color(0xC7771E))
    context.fillEllipse(in: CGRect(x: 319, y: 341, width: 58, height: 58))
    roundedRect(CGRect(x: 396, y: 347, width: 226, height: 46), radius: 23, fill: color(0xC7771E), context: context)
    roundedRect(CGRect(x: 394, y: 148, width: 236, height: 34), radius: 17, fill: color(0xC7771E), context: context)

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
    try render(size: slot.pixels, destination: output.appendingPathComponent(slot.filename))
}
print("Generated \(slots.count) opaque Pocket Daily app icons in \(output.path)")
