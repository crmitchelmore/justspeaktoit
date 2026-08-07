import AppKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import SpeakApp

/// Snapshot tests for mac SwiftUI views that render deterministically headless.
///
/// Determinism rules (CI runs these on GitHub's `macos-26-arm64` image):
/// - Every snapshot is rendered at a pinned point size into a 1x bitmap, so
///   Retina development machines and 1x CI displays produce identical pixels.
/// - Appearance is pinned to Aqua (light) so the host's dark-mode setting is
///   irrelevant.
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

    let controller = NSHostingController(
      rootView: view.environment(\.colorScheme, .light)
    )
    withSnapshotTesting(record: .never) {
      assertSnapshot(
        of: controller.view,
        as: .pinnedImage(size: size),
        file: file,
        testName: testName,
        line: line
      )
    }
  }
}

extension Snapshotting where Value == NSView, Format == NSImage {
  /// Renders an `NSView` at an exact point size into a 1x bitmap.
  ///
  /// Unlike the built-in `.image` strategy this never inherits the host
  /// screen's backing scale factor, so references recorded on a Retina
  /// machine compare byte-for-byte on non-Retina CI displays. A small
  /// perceptual tolerance absorbs GPU/anti-aliasing differences between
  /// point releases of the same macOS major version.
  static func pinnedImage(
    size: CGSize,
    precision: Float = 0.99,
    perceptualPrecision: Float = 0.98
  ) -> Snapshotting {
    Snapshotting<NSImage, NSImage>
      .image(precision: precision, perceptualPrecision: perceptualPrecision)
      .pullback { view in
        // Host in an offscreen window so materials, vibrancy, and SwiftUI
        // layout behave as they do in the real app.
        let window = NSWindow(
          contentRect: CGRect(origin: .zero, size: size),
          styleMask: [.borderless],
          backing: .buffered,
          defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        guard
          let rep = NSBitmapImageRep(
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
          )
        else {
          fatalError("Could not create bitmap representation for snapshot")
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
      }
  }
}
