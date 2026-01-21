#!/usr/bin/env swift
// Generates DMG installer background with drag-to-Applications visual
// Run with: swift scripts/generate-dmg-background.swift

import AppKit

let width: CGFloat = 660
let height: CGFloat = 400
let outputPath = "Resources/dmg-background.png"
let retinaOutputPath = "Resources/dmg-background@2x.png"

func generateBackground(scale: CGFloat) -> NSImage {
    let size = NSSize(width: width * scale, height: height * scale)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(origin: .zero, size: size)
    let ctx = NSGraphicsContext.current!.cgContext
    
    // Scale for retina
    ctx.scaleBy(x: scale, y: scale)
    let scaledRect = NSRect(x: 0, y: 0, width: width, height: height)

    // Soft gradient background (warm cream to light peach)
    let bgGradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.95, alpha: 1.0),
        NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.90, alpha: 1.0),
        NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.87, alpha: 1.0)
    ])
    bgGradient?.draw(in: scaledRect, angle: -90)

    // Subtle pattern overlay
    NSColor(calibratedWhite: 1.0, alpha: 0.3).setFill()
    for y in stride(from: 0, to: height, by: 20) {
        let stripe = NSRect(x: 0, y: y, width: width, height: 1)
        stripe.fill()
    }

    // Arrow from app position to Applications position
    let arrowPath = NSBezierPath()
    let arrowStartX: CGFloat = 200
    let arrowEndX: CGFloat = 460
    let arrowY: CGFloat = 200
    
    // Curved arrow
    arrowPath.move(to: NSPoint(x: arrowStartX, y: arrowY))
    arrowPath.curve(
        to: NSPoint(x: arrowEndX - 20, y: arrowY),
        controlPoint1: NSPoint(x: arrowStartX + 60, y: arrowY + 40),
        controlPoint2: NSPoint(x: arrowEndX - 80, y: arrowY + 40)
    )
    
    // Arrow styling
    NSColor(calibratedRed: 0.4, green: 0.4, blue: 0.45, alpha: 0.5).setStroke()
    arrowPath.lineWidth = 3
    arrowPath.lineCapStyle = .round
    arrowPath.stroke()
    
    // Arrowhead
    let arrowHead = NSBezierPath()
    arrowHead.move(to: NSPoint(x: arrowEndX - 35, y: arrowY + 12))
    arrowHead.line(to: NSPoint(x: arrowEndX - 15, y: arrowY))
    arrowHead.line(to: NSPoint(x: arrowEndX - 35, y: arrowY - 12))
    arrowHead.lineWidth = 3
    arrowHead.lineCapStyle = .round
    arrowHead.lineJoinStyle = .round
    arrowHead.stroke()

    // "Drag to install" text
    let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(calibratedRed: 0.35, green: 0.35, blue: 0.4, alpha: 0.8)
    ]
    let text = "Drag to Applications to install"
    let textSize = text.size(withAttributes: textAttributes)
    let textPoint = NSPoint(x: (width - textSize.width) / 2, y: 90)
    text.draw(at: textPoint, withAttributes: textAttributes)
    
    // App name at top
    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: NSColor(calibratedRed: 0.25, green: 0.25, blue: 0.3, alpha: 1.0)
    ]
    let title = "Just Speak to It"
    let titleSize = title.size(withAttributes: titleAttributes)
    let titlePoint = NSPoint(x: (width - titleSize.width) / 2, y: height - 60)
    title.draw(at: titlePoint, withAttributes: titleAttributes)

    // Version text
    let versionAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.55, alpha: 0.8)
    ]
    let version = "Voice transcription, reimagined"
    let versionSize = version.size(withAttributes: versionAttributes)
    let versionPoint = NSPoint(x: (width - versionSize.width) / 2, y: height - 85)
    version.draw(at: versionPoint, withAttributes: versionAttributes)

    return image
}

// Generate 1x
let image1x = generateBackground(scale: 1)
if let tiffData = image1x.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiffData),
   let pngData = bitmap.representation(using: .png, properties: [:]) {
    try? pngData.write(to: URL(fileURLWithPath: outputPath))
    print("Generated: \(outputPath)")
}

// Generate 2x (retina)
let image2x = generateBackground(scale: 2)
if let tiffData = image2x.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiffData),
   let pngData = bitmap.representation(using: .png, properties: [:]) {
    try? pngData.write(to: URL(fileURLWithPath: retinaOutputPath))
    print("Generated: \(retinaOutputPath)")
}

print("\nDMG background images generated!")
