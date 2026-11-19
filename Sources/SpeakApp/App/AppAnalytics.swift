import Combine
import Foundation
import SpeakCore

/// Product analytics for one app run: the controller, its consent kept in step
/// with the Settings toggle, and the once-a-day active event.
@MainActor
final class AppAnalytics {
  let controller: ProductAnalyticsController
  #if !APP_STORE
  let privacyControls: AnalyticsPrivacyControls
  #endif
  private var consentObserver: AnyCancellable?

  init(services: WireUp.AnalyticsServices) {
    controller = services.controller
    #if !APP_STORE
    privacyControls = services.privacyControls
    #endif
  }

  /// Syncs the initial consent, fires the daily-active event when opted in, and
  /// follows later changes to the analytics setting.
  func start(settings: AppSettings, dailyGate: AppActiveDailyGate = AppActiveDailyGate()) {
    let controller = controller
    let initiallyEnabled = settings.analyticsEnabled
    Task {
      try? await controller.setConsent(initiallyEnabled ? .optedIn : .optedOut)
      #if !APP_STORE
      await privacyControls.refresh()
      #endif
      let today = dailyGate.startOfToday()
      if initiallyEnabled, dailyGate.isDue(on: today) {
        try? await controller.capture(.appActiveDaily)
        dailyGate.markCaptured(on: today)
      }
    }
    consentObserver = settings.$analyticsEnabled
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak controller, weak self] enabled in
        guard let controller else { return }
        #if !APP_STORE
        self?.privacyControls.invalidate()
        #endif
        Task {
          try? await controller.setConsent(enabled ? .optedIn : .optedOut)
          #if !APP_STORE
          await self?.privacyControls.refresh()
          #endif
          if enabled { try? await controller.capture(.analyticsOptIn(surface: .settings)) }
        }
      }
  }

  /// No-op unless the user has opted in; the controller enforces consent.
  func capture(_ event: ProductAnalyticsEvent) {
    let controller = controller
    Task { try? await controller.capture(event) }
  }

  func captureOnboardingCompletedAfterConsent() {
    let controller = controller
    Task {
      try? await controller.setConsent(.optedIn)
      try? await controller.capture(.onboardingCompleted(stepsSkipped: .zero))
    }
  }
}

/// Fires `app_active_daily` at most once per calendar day.
struct AppActiveDailyGate {
  static let lastCaptureKey = "posthog.lastActiveDailyCaptureDate"

  var defaults: UserDefaults = .standard
  var calendar: Calendar = .current
  var now: () -> Date = Date.init

  func startOfToday() -> Date {
    calendar.startOfDay(for: now())
  }

  func isDue(on today: Date) -> Bool {
    guard let lastCapture = defaults.object(forKey: Self.lastCaptureKey) as? Date else { return true }
    return !calendar.isDate(lastCapture, inSameDayAs: today)
  }

  func markCaptured(on today: Date) {
    defaults.set(today, forKey: Self.lastCaptureKey)
  }
}
