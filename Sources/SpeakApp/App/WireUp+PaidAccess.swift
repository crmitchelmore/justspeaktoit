import Foundation
import SpeakCore

/// Paid access assembly: the subscription-routed client in front of the user's own keys.
extension WireUp {
  // Paid access wraps, rather than replaces, the bring-your-own-key client.
  // Without a verified entitlement every request goes straight through to
  // `openRouter`, so subscribers and non-subscribers share one code path and
  // an outage degrades to the user's own keys instead of breaking dictation.
  static func makePaidAccessRouting(
    openRouter: OpenRouterAPIClient,
    secureStorage: SecureAppStorage,
    settings: AppSettings
  ) -> (PaidAccessManager, PaidAccessProxyClient) {
    let paidClient = PaidAccessHTTPClient(baseURL: PaidAccessFeature.baseURL)
    let paidAccess = PaidAccessManager(
      client: paidClient,
      sessionStore: AppSecureStorageSessionStore(storage: secureStorage),
      settings: settings
    )
    let routedClient = PaidAccessProxyClient(
      fallback: openRouter,
      paidClient: paidClient,
      sessionProvider: paidAccess.sessionProvider(),
      routerProvider: paidAccess.routerProvider()
    )
    return (paidAccess, routedClient)
  }

  static func restorePaidAccessEntitlement(in environment: AppEnvironment) {
    guard PaidAccessFeature.isEnabled else { return }
    // Routing waits briefly for this launch restore, preventing a subscriber's
    // first dictation from racing it and falling back to an unconfigured key.
    Task { @MainActor in
      environment.paidAccess.restoreEntitlementAtLaunch()
    }
  }
}
