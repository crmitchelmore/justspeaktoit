import AppKit
import Foundation
import SpeakCore

/// Product analytics assembly: PostHog for direct downloads only, behind consent.
extension WireUp {
  struct AnalyticsServices {
    let controller: ProductAnalyticsController
    #if !APP_STORE
    let privacyControls: AnalyticsPrivacyControls
    #endif
  }

  static func makeAnalyticsController(
    settings: AppSettings,
    fileManager: FileManager
  ) -> AnalyticsServices? {
    #if APP_STORE
    return nil
    #else
    guard DistributionChannel.current == .direct else { return nil }
    guard PostHogProductAnalyticsSink.isConfigured else { return nil }
    let stateURL = (fileManager
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? fileManager.homeDirectoryForCurrentUser)
      .appendingPathComponent(ReleaseTrain.current.supportDirectory)
      .appendingPathComponent("analytics_state.json")
    let queueURL = stateURL.deletingLastPathComponent().appendingPathComponent("analytics_queue.json")
    let stateStore = FileProductAnalyticsStateStore(fileURL: stateURL)
    let context = buildAnalyticsContext()
    let policy = AnalyticsLocalPolicy()
    let sink = PostHogProductAnalyticsSink(queueURL: queueURL, forceDisabled: { policy.isDisabled })
    guard let controller = try? ProductAnalyticsController(
      context: context,
      sink: sink,
      stateStore: stateStore,
      forceDisabled: { policy.isDisabled }
    ) else { return nil }
    return AnalyticsServices(
      controller: controller,
      privacyControls: AnalyticsPrivacyControls(controller: controller, sink: sink, policy: policy)
    )
    #endif
  }

  private static func buildAnalyticsContext() -> ProductAnalyticsContext {
    let bundle = Bundle.main
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    let osMajorMinor = "\(osVersion.majorVersion).\(osVersion.minorVersion)"
    let localeCode = Locale.current.language.languageCode?.identifier ?? "en"
    let distributionChannel: AnalyticsDistributionChannel = DistributionChannel.current == .appStore
      ? .macAppStore
      : .direct
    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "x86_64"
    #endif
    return ProductAnalyticsContext(
      platform: .macOS,
      appVersion: version,
      build: build,
      osMajorMinor: osMajorMinor,
      distributionChannel: distributionChannel,
      localeLanguageCode: localeCode,
      architecture: arch
    )
  }
}
