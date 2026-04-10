import Foundation
import XCTest

@testable import SpeakApp

final class HUDPlatformWorkaroundsTests: XCTestCase {
  func testLegacyRenderingEnabledOnMacOS26Dot0() {
    XCTAssertTrue(
      HUDPlatformWorkarounds.shouldUseLegacyRendering(
        for: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
      )
    )
    XCTAssertTrue(
      HUDPlatformWorkarounds.shouldUseLegacyRendering(
        for: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 5)
      )
    )
  }

  func testLegacyRenderingDisabledOutsideMacOS26Dot0() {
    XCTAssertFalse(
      HUDPlatformWorkarounds.shouldUseLegacyRendering(
        for: OperatingSystemVersion(majorVersion: 25, minorVersion: 6, patchVersion: 0)
      )
    )
    XCTAssertFalse(
      HUDPlatformWorkarounds.shouldUseLegacyRendering(
        for: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
      )
    )
    XCTAssertFalse(
      HUDPlatformWorkarounds.shouldUseLegacyRendering(
        for: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
      )
    )
  }

  func testGlassEffectDisabledForAllMacOS26Builds_OnlyEnablesOnMacOS27OrLater() {
    XCTAssertFalse(
      HUDPlatformWorkarounds.canUseGlassEffect(
        on: OperatingSystemVersion(majorVersion: 25, minorVersion: 6, patchVersion: 0)
      )
    )
    XCTAssertFalse(
      HUDPlatformWorkarounds.canUseGlassEffect(
        on: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
      )
    )
    XCTAssertFalse(
      HUDPlatformWorkarounds.canUseGlassEffect(
        on: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
      )
    )
    XCTAssertFalse(
      HUDPlatformWorkarounds.canUseGlassEffect(
        on: OperatingSystemVersion(majorVersion: 26, minorVersion: 3, patchVersion: 1)
      )
    )
    XCTAssertTrue(
      HUDPlatformWorkarounds.canUseGlassEffect(
        on: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
      )
    )
  }
}
