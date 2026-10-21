#!/usr/bin/env swift
import AppKit

// A 640 × 360 point Finder background, rendered at Retina resolution.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 720,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current!.cgContext.scaleBy(x: 2, y: 2)
NSColor(srgbRed: 0.94, green: 0.96, blue: 0.98, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 640, height: 360).fill()

func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(srgbRed: 0.15, green: 0.23, blue: 0.30, alpha: 1)
    ]
    let string = value as NSString
    let width = string.size(withAttributes: attributes).width
    string.draw(at: NSPoint(x: (640 - width) / 2, y: y), withAttributes: attributes)
}

text("Install SlurmBar", y: 290, size: 26, weight: .semibold)
text("Drag SlurmBar to Applications", y: 58, size: 16, weight: .regular)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 284, y: 190))
arrow.line(to: NSPoint(x: 356, y: 190))
arrow.move(to: NSPoint(x: 340, y: 206))
arrow.line(to: NSPoint(x: 356, y: 190))
arrow.line(to: NSPoint(x: 340, y: 174))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(srgbRed: 0.36, green: 0.48, blue: 0.57, alpha: 1).setStroke()
arrow.stroke()
NSGraphicsContext.restoreGraphicsState()
bitmap.size = NSSize(width: 640, height: 360)
try bitmap.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
