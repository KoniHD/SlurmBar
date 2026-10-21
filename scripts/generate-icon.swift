#!/usr/bin/env swift
import AppKit

// Vector artwork rendered at every macOS icon size; no external design dependencies.
func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 196, yRadius: 196)
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.23, blue: 0.31, alpha: 1),
                        NSColor(srgbRed: 0.025, green: 0.07, blue: 0.14, alpha: 1)])!.draw(in: tile, angle: -65)
    NSColor.white.withAlphaComponent(0.14).setStroke()
    tile.lineWidth = 3
    tile.stroke()
    let green = NSColor(srgbRed: 0.23, green: 0.88, blue: 0.67, alpha: 1)
    let orange = NSColor(srgbRed: 1, green: 0.72, blue: 0.28, alpha: 1)
    let red = NSColor(srgbRed: 0.98, green: 0.36, blue: 0.38, alpha: 1)
    for (index, y) in [650.0, 448.0, 246.0].enumerated() {
        let card = NSBezierPath(roundedRect: NSRect(x: 210, y: y, width: 604, height: 150), xRadius: 32, yRadius: 32)
        NSColor.white.withAlphaComponent(0.09).setFill()
        card.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        card.lineWidth = 3
        card.stroke()
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: 252, y: y + 96, width: [176.0, 128.0, 204.0][index], height: 12), xRadius: 6, yRadius: 6).fill()
        green.setFill()
        NSBezierPath(ovalIn: NSRect(x: 746, y: y + 96, width: 14, height: 14)).fill()
        let track = NSBezierPath(roundedRect: NSRect(x: 252, y: y + 34, width: 508, height: 30), xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        let widths: [[CGFloat]] = [[304, 112, 92], [170, 220, 118], [370, 66, 72]]
        var x: CGFloat = 252
        for (color, width) in zip([green, orange, red], widths[index]) {
            color.setFill()
            NSRect(x: x, y: y + 34, width: width, height: 30).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
// ICNS PNG representations, including Retina variants. Writing the container directly
// also works when iconutil's image conversion helper is unavailable in a sandbox.
func bigEndian(_ value: Int) -> Data {
    var number = UInt32(value).bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}
var representations = Data()
for (type, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                     ("ic08", 256), ("ic09", 512), ("ic10", 1024),
                     ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)] {
    let png = render(size: size)
    representations.append(Data(type.utf8))
    representations.append(bigEndian(png.count + 8))
    representations.append(png)
}
var icon = Data("icns".utf8)
icon.append(bigEndian(representations.count + 8))
icon.append(representations)
try icon.write(to: resources.appendingPathComponent("AppIcon.icns"))
try render(size: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))
