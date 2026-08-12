import AppKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import SpeakApp

/// Snapshot tests for mac SwiftUI views that render deterministically headless.
///
/// Determinism rules (CI runs these on GitHub's `macos-26-arm64` image):
/// - Views are rasterised with SwiftUI's `ImageRenderer` at a pinned 1x scale
///   rather than through an off-screen `NSWindow`. Window-backed rendering
///   inherits the host's backing scale factor and needs the window server for
///   compositor effects, which is why a Retina development Mac and a headless
///   1x CI runner disagreed on shadows and translucency.
/// - Font smoothing (stem dilation) is disabled on the drawing context. It is
///   applied on 1x displays and skipped on Retina ones, so leaving it to the
///   host makes every glyph edge host-dependent.
/// - `colorScheme` is pinned to light so the host's dark-mode setting is
///   irrelevant. `ImageRenderer` draws purely through Core Graphics, so
///   window-server-backed effects (materials, vibrancy, Liquid Glass) are
///   flattened identically on every host instead of depending on whether a
///   display is attached.
/// - Only static view states are snapshotted. HUD phases whose glyphs animate
///   via `TimelineView(.animation)` (recording/transcribing/failure) and views
///   that format `Date`/`Decimal` with `Locale.current` (history rows) are
///   deliberately excluded because their output varies run-to-run or
///   machine-to-machine.
/// - Tests skip (not fail) on any macOS major version other than the one the
///   references were recorded on, so a runner-image upgrade prompts a
///   re-record instead of flaking PR CI.
@MainActor
final class ViewSnapshotTests: XCTestCase {
  /// macOS major version the committed references were recorded on.
  /// If CI moves to a newer image, re-record with `withSnapshotTesting(record: .all)`
  /// and bump this constant.
  private static let referenceOSMajorVersion = 26

  // MARK: - HUD

  func testHUDOverlay_successPhase() throws {
    let settings = Self.makeScratchSettings()
    let manager = HUDManager(appSettings: settings)
    manager.finishSuccess(message: "Inserted into Notes")

    let view = HUDOverlay(manager: manager)
      .environmentObject(settings)

    try Self.assertDeterministicSnapshot(of: view, size: CGSize(width: 480, height: 240))
  }

  // MARK: - Latency badges

  func testLatencyBadge_allTiersAndStyles() throws {
    let view = VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        LatencyBadge(tier: .instant, estimatedMs: 50)
        LatencyBadge(tier: .fast, estimatedMs: 500)
        LatencyBadge(tier: .medium, estimatedMs: 1500)
        LatencyBadge(tier: .slow, estimatedMs: 3000)
      }
      HStack(spacing: 10) {
        LatencyBadgeCompact(tier: .instant)
        LatencyBadgeCompact(tier: .fast)
        LatencyBadgeCompact(tier: .medium)
        LatencyBadgeCompact(tier: .slow)
      }
      HStack(spacing: 10) {
        LatencyBadgeCompact(tier: .instant, emphasized: true)
        LatencyBadgeCompact(tier: .fast, emphasized: true)
        LatencyBadgeCompact(tier: .medium, emphasized: true)
        LatencyBadgeCompact(tier: .slow, emphasized: true)
      }
    }
    .padding(16)

    try Self.assertDeterministicSnapshot(of: view, size: CGSize(width: 340, height: 140))
  }

  // MARK: - Audio level meter

  func testAudioLevelMeter_levels() throws {
    let view = VStack(alignment: .leading, spacing: 10) {
      ForEach([Float(0), 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
        AudioLevelMeterView(level: level, animatesLevel: false, width: 160, height: 6)
      }
      SegmentedAudioLevelMeterView(level: 0.6, width: 160, height: 8)
    }
    .padding(16)

    try Self.assertDeterministicSnapshot(of: view, size: CGSize(width: 200, height: 120))
  }

  // MARK: - Helpers

  /// A fresh `AppSettings` backed by an empty scratch suite so host-machine
  /// defaults can never leak into rendering.
  private static func makeScratchSettings() -> AppSettings {
    let suiteName = "ViewSnapshotTests-scratch"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return AppSettings(defaults: defaults)
  }

  private static func assertDeterministicSnapshot<V: View>(
    of view: V,
    size: CGSize,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line
  ) throws {
    let hostMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    guard hostMajor == referenceOSMajorVersion else {
      throw XCTSkip(
        "Snapshot references were recorded on macOS \(referenceOSMajorVersion); host is macOS "
          + "\(hostMajor). Re-record with `withSnapshotTesting(record: .all)` and bump "
          + "`referenceOSMajorVersion`."
      )
    }

    let image = try Self.render(view, size: size)
    withSnapshotTesting(record: .never) {
      assertSnapshot(
        of: image,
        as: .image(precision: 0.99, perceptualPrecision: 0.98),
        file: file,
        testName: testName,
        line: line
      )
    }
  }

  /// Rasterises a view at an exact point size into a 1x bitmap.
  ///
  /// Everything host-dependent is pinned here: the rasterisation scale (so a
  /// Retina Mac cannot bake 2x content into the reference), font smoothing (so
  /// glyph edges do not depend on the attached display), and the appearance.
  /// `ImageRenderer` deliberately replaces the previous off-screen `NSWindow`:
  /// window-backed rendering needs the window server for shadows and
  /// translucency, which a headless CI runner draws differently.
  private static func render(_ view: some View, size: CGSize) throws -> NSImage {
    let renderer = ImageRenderer(
      content: view
        .environment(\.colorScheme, .light)
        .frame(width: size.width, height: size.height)
    )
    renderer.scale = 1
    renderer.isOpaque = false

    let representation = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      "Could not create bitmap representation for snapshot"
    )
    let context = try XCTUnwrap(
      NSGraphicsContext(bitmapImageRep: representation),
      "Could not create drawing context for snapshot"
    )
    context.cgContext.setAllowsFontSmoothing(false)
    context.cgContext.setShouldSmoothFonts(false)

    renderer.render(rasterizationScale: 1) { _, draw in
      draw(context.cgContext)
    }

    let image = NSImage(size: size)
    image.addRepresentation(representation)
    return image
  }
}
