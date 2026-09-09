#!/usr/bin/env swift
// Canonical brand artwork; run from the repository root with Apple's Swift.
// Explicit pixel buffers avoid lockFocus() inheriting the display's Retina scale.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let heights: [CGFloat] = [208, 368, 544, 368, 208]
let barWidth: CGFloat = 80
let barStep: CGFloat = 124
let firstBarX: CGFloat = 224
enum Appearance { case standard, dark, tinted }

func colour(_ hex: String) -> NSColor {
    let value = UInt32(hex, radix: 16)!
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}
func palette(_ appearance: Appearance) -> (String, String, String) {
    switch appearance {
    case .standard: return ("FF6B3D", "FF9C4A", "181B1D")
    case .dark: return ("20292C", "181B1D", "FF6B3D")
    case .tinted: return ("242424", "121212", "EAEAEA")
    }
}
func write(_ data: Data, to relativePath: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
func png(size: Int, appearance: Appearance = .standard, mac: Bool = false) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha = mac ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: space, bitmapInfo: alpha.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    if mac {
        // macOS inset; iOS/watchOS supply their mask and require opaque corners.
        context.translateBy(x: 64, y: 64)
        context.scaleBy(x: 0.875, y: 0.875)
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                     xRadius: 224, yRadius: 224).addClip()
    }
    let (top, bottom, ink) = palette(appearance)
    NSGradient(starting: colour(bottom), ending: colour(top))!
        .draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 90)
    for (index, height) in heights.enumerated() {
        let rect = NSRect(x: firstBarX + CGFloat(index) * barStep,
                          y: (1024 - height) / 2, width: barWidth, height: height)
        colour(ink).setFill()
        NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}
func svg(appearance: Appearance = .standard, rounded: Bool = true) -> String {
    let (top, bottom, ink) = palette(appearance)
    let bars = heights.enumerated().map { index, height in
        "<rect x=\"\(Int(firstBarX + CGFloat(index) * barStep))\" y=\"\(Int((1024 - height) / 2))\" width=\"80\" height=\"\(Int(height))\" rx=\"40\"/>"
    }.joined(separator: "\n    ")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <defs><linearGradient id="surface" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#\(top)"/><stop offset="1" stop-color="#\(bottom)"/></linearGradient></defs>
      <rect width="1024" height="1024" rx="\(rounded ? 224 : 0)" fill="url(#surface)"/>
      <g fill="#\(ink)">
        \(bars)
      </g>
    </svg>
    """
}
for points in [16, 32, 64, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try write(png(size: points * scale, mac: true),
                  to: "Resources/AppIcon.iconset/icon_\(points)x\(points)\(suffix).png")
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "Resources/AppIcon.iconset", "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try write(Data(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns")),
          to: "Sources/SpeakApp/Resources/AppIcon.icns")
for (appearance, name) in [(Appearance.standard, "AppIcon"), (.dark, "AppIcon-dark"), (.tinted, "AppIcon-tinted")] {
    try write(png(size: 1024, appearance: appearance), to: "SpeakiOSApp/Assets.xcassets/AppIcon.appiconset/\(name).png")
    try write(Data(svg(appearance: appearance, rounded: false).utf8), to: "Resources/Brand/\(name).svg")
}
try write(png(size: 1024), to: "JustSpeakWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try write(Data(svg().utf8), to: "landing-page/favicon.svg")
for (size, name) in [(32, "favicon-32.png"), (180, "apple-touch-icon.png"), (192, "icon-192.png"), (512, "icon-512.png")] {
    try write(png(size: size), to: "landing-page/\(name)")
}
// Launch marks retain an adaptive circular field and the same waveform proportions.
for (appearance, name) in [(Appearance.standard, "LaunchMark.svg"), (.dark, "LaunchMark-dark.svg")] {
    let (_, _, ink) = palette(appearance)
    let background = appearance == .standard ? "FF6B3D" : "181B1D"
    let bars = heights.enumerated().map { index, height in
        "<rect x=\"\(30 + index * 11)\" y=\"\(56 - Int(height * 0.11) / 2)\" width=\"8\" height=\"\(Int(height * 0.11))\" rx=\"4\"/>"
    }.joined(separator: "\n    ")
    try write(Data("""
    <svg xmlns="http://www.w3.org/2000/svg" width="112" height="112" viewBox="0 0 112 112">
      <circle cx="56" cy="56" r="52" fill="#\(background)"/>
      <g fill="#\(ink)">
        \(bars)
      </g>
    </svg>
    """.utf8), to: "SpeakiOSApp/Assets.xcassets/LaunchMark.imageset/\(name)")
}
print("Generated Mac iconset/ICNS, iOS appearances, watch icon, web icons and launch marks.")
