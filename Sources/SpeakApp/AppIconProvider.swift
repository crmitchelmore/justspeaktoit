import AppKit

enum AppIconProvider {
  private static let iconSize = NSSize(width: 512, height: 512)

  private static let cachedIcon: NSImage = {
    let image = NSImage(size: iconSize)
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(origin: .zero, size: iconSize)
    let outerRadius = iconSize.width * 0.18
    let outerPath = NSBezierPath(roundedRect: rect, xRadius: outerRadius, yRadius: outerRadius)
    outerPath.addClip()

    let backgroundGradient = NSGradient(
      colors: [
        NSColor(calibratedRed: 0.30, green: 0.36, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.54, green: 0.27, blue: 0.94, alpha: 1.0),
        NSColor(calibratedRed: 0.98, green: 0.30, blue: 0.61, alpha: 1.0),
      ]
    )
    backgroundGradient?.draw(in: rect, angle: 220)

    let highlightPath = NSBezierPath()
    let highlightStart = NSPoint(x: rect.minX, y: rect.maxY * 0.55)
    let highlightEnd = NSPoint(x: rect.maxX, y: rect.maxY * 0.85)
    highlightPath.move(to: highlightStart)
    highlightPath.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
    highlightPath.line(to: NSPoint(x: rect.minX, y: rect.maxY))
    highlightPath.close()
    NSColor.white.withAlphaComponent(0.14).setFill()
    highlightPath.fill()

    let innerRect = rect.insetBy(dx: iconSize.width * 0.23, dy: iconSize.height * 0.25)
    let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: 42, yRadius: 42)
    NSColor.white.withAlphaComponent(0.85).setFill()
    innerPath.fill()

    let waveRect = innerRect.insetBy(dx: innerRect.width * 0.18, dy: innerRect.height * 0.34)
    let barCount = 5
    let barSpacing = waveRect.width / CGFloat(barCount * 2 - 1)
    let barWidth = barSpacing
    let maxBarHeight = waveRect.height
    let heights: [CGFloat] = [0.45, 0.8, 1.0, 0.72, 0.5]
    let barColor = NSColor(calibratedRed: 0.24, green: 0.20, blue: 0.50, alpha: 1.0)
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

    let glowPath = NSBezierPath(ovalIn: innerRect.insetBy(dx: -24, dy: -24))
    NSColor.white.withAlphaComponent(0.08).setStroke()
    glowPath.lineWidth = 18
    glowPath.stroke()

    image.isTemplate = false
    return image
  }()

  static func applicationIcon() -> NSImage {
    cachedIcon
  }
}
