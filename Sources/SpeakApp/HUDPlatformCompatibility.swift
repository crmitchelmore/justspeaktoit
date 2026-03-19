import Foundation

enum HUDPlatformWorkarounds {
  #if os(macOS)
  static func shouldUseLegacyRendering(
    for version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
  ) -> Bool {
    version.majorVersion == 26 && version.minorVersion == 0
  }

  static func canUseGlassEffect(
    on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
  ) -> Bool {
    guard version.majorVersion >= 26 else { return false }
    return !shouldUseLegacyRendering(for: version)
  }

  static var isLegacyRenderingEnabled: Bool {
    shouldUseLegacyRendering()
  }

  static var shouldAnimateHUD: Bool {
    !isLegacyRenderingEnabled
  }
  #else
  static func shouldUseLegacyRendering(for version: OperatingSystemVersion = .init()) -> Bool {
    false
  }

  static func canUseGlassEffect(on version: OperatingSystemVersion = .init()) -> Bool {
    false
  }

  static var isLegacyRenderingEnabled: Bool {
    false
  }

  static var shouldAnimateHUD: Bool {
    true
  }
  #endif

  static var elapsedTimerInterval: TimeInterval {
    isLegacyRenderingEnabled ? 0.1 : 0.02
  }
}
