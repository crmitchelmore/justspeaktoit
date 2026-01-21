#!/usr/bin/env swift
// Generates AppIcon.icns from programmatic icon definition
// Run with: swift scripts/generate-icon.swift

import AppKit

let iconSizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDir = "Resources/AppIcon.iconset"

func generateIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(origin: .zero, size: NSSize(width: size, height: size))
    let outerRadius = size * 0.18
    let outerPath = NSBezierPath(roundedRect: rect, xRadius: outerRadius, yRadius: outerRadius)
    outerPath.addClip()

    // Orange gradient background
    let backgroundGradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.24, alpha: 1.0),
            NSColor(calibratedRed: 1.00, green: 0.61, blue: 0.29, alpha: 1.0),
            NSColor(calibratedRed: 1.00, green: 0.48, blue: 0.36, alpha: 1.0),
        ]
    )
    backgroundGradient?.draw(in: rect, angle: 220)

    // Subtle highlight
    let highlightPath = NSBezierPath()
    let highlightStart = NSPoint(x: rect.minX, y: rect.maxY * 0.55)
    highlightPath.move(to: highlightStart)
    highlightPath.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
    highlightPath.line(to: NSPoint(x: rect.minX, y: rect.maxY))
    highlightPath.close()
    NSColor.white.withAlphaComponent(0.14).setFill()
    highlightPath.fill()

    // White rounded rectangle
    let innerRect = rect.insetBy(dx: size * 0.23, dy: size * 0.25)
    let innerRadius = size * 0.082
    let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: innerRadius, yRadius: innerRadius)
    NSColor.white.withAlphaComponent(0.85).setFill()
    innerPath.fill()

    // Sound wave bars
    let waveRect = innerRect.insetBy(dx: innerRect.width * 0.18, dy: innerRect.height * 0.34)
    let barCount = 5
    let barSpacing = waveRect.width / CGFloat(barCount * 2 - 1)
    let barWidth = barSpacing
    let maxBarHeight = waveRect.height
    let heights: [CGFloat] = [0.45, 0.8, 1.0, 0.72, 0.5]
    let barColor = NSColor(calibratedRed: 0.35, green: 0.18, blue: 0.12, alpha: 1.0)
    
    for index in 0..<barCount {
        let heightFactor = index < heights.count ? heights[index] : 0.6
        let barHeight = maxBarHeight * heightFactor
        let xOffset = waveRect.minX + CGFloat(index * 2) * barSpacing
        let barRect = NSRect(
            x: xOffset,
            y: waveRect.midY - barHeight / 2,
            width: barWidth,
            height: barHeight
        )
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        barColor.setFill()
        barPath.fill()
    }

    // Outer glow
    let glowPath = NSBezierPath(ovalIn: innerRect.insetBy(dx: -size * 0.047, dy: -size * 0.047))
    NSColor.white.withAlphaComponent(0.08).setStroke()
    glowPath.lineWidth = size * 0.035
    glowPath.stroke()

    image.isTemplate = false
    return image
}

// Create iconset directory
let fileManager = FileManager.default
try? fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// Generate all icon sizes
for size in iconSizes {
    let image = generateIcon(size: CGFloat(size))
    
    // Save 1x
    if size <= 512 {
        let filename = "icon_\(size)x\(size).png"
        let path = "\(outputDir)/\(filename)"
        if let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: path))
            print("Generated: \(filename)")
        }
    }
    
    // Save @2x (use double-size image for half the dimension name)
    if size >= 32 {
        let halfSize = size / 2
        let filename = "icon_\(halfSize)x\(halfSize)@2x.png"
        let path = "\(outputDir)/\(filename)"
        if let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: path))
            print("Generated: \(filename)")
        }
    }
}

print("\nNow run: iconutil -c icns \(outputDir) -o Resources/AppIcon.icns")
