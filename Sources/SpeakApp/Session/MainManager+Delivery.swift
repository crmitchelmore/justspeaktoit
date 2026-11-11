import AppKit
import Foundation
import SpeakCore

/// Delivery messaging and the settings remedy offered after a delivery that
/// did not land where the user expected.
extension MainManager {
  /// HUD headline for a one-shot delivery that did not insert text. Holding
  /// the transcript back because the user left the app it was going to is a
  /// safety choice, not a failure.
  static func deliveryFailureHeadline(for error: Error) -> String {
    switch error as? TextOutputError {
    case .originalApplicationNotInFront, .destinationApplicationChanged:
      return "Not inserted"
    default:
      return "Delivery failed"
    }
  }

  /// Error text for History. History can be exported to a public GitHub
  /// issue, so it must not name the user's apps.
  static func historySafeDescription(of error: Error) -> String {
    (error as? TextOutputError)?.historySafeDescription ?? error.localizedDescription
  }

  /// The remedy, if any, for a one-shot delivery outcome under the current settings.
  static func remedy(forDelivery outputResult: TextOutputResult, settings: AppSettings) -> DeliverySettingsRemedy? {
    DeliverySettingsRemedy.forOutput(
      error: outputResult.error,
      warning: outputResult.warning,
      focusMovedToOtherApplication: outputResult.focusMovedToOtherApplication,
      configuration: DeliverySettingsRemedy.Configuration(settings: settings)
    )
  }

  /// What to tell the user about a delivery that succeeded but not quite as
  /// they may have expected, with the setting that would change it. Nil when
  /// there is nothing to say.
  static func deliveryNote(
    warning: Error?,
    focusMovedToOtherApplication: Bool,
    destination: String?,
    remedy: DeliverySettingsRemedy?
  ) -> String? {
    let base: String
    if focusMovedToOtherApplication {
      base = destination.map { "Sent to \($0), where recording started." }
        ?? "Sent to the app where recording started."
    } else if let warning {
      base = warning.localizedDescription
    } else {
      return nil
    }
    return remedy.annotate(base)
  }

  static func deliverySuccessMessage(
    note: String?,
    stopRequested: Date?,
    delivered: Date?
  ) -> String {
    if let note {
      return "Delivered — \(note)"
    }
    guard let stopToFinalMs = SessionLatencyMetrics.milliseconds(
      from: stopRequested,
      to: delivered
    ) else {
      return "Delivered"
    }
    return "Delivered in \(SessionLatencyMetrics.formattedMilliseconds(stopToFinalMs))"
  }

  func captureFirstTranscriptionSucceededIfNeeded(session: ActiveSession) {
    guard appSettings.analyticsEnabled, let analyticsCapture else { return }
    guard let modelIdentifier = session.transcriptionResult?.modelIdentifier else { return }
    let analytics = FirstTranscriptionAnalytics(defaults: .standard)
    let isOnDevice = appSettings.transcriptionMode == .localModel
    guard let event = analytics.eventIfFirst(modelIdentifier: modelIdentifier, isOnDevice: isOnDevice) else { return }
    analyticsCapture(event)
  }

  /// Records a delivery that inserted nothing: History, the HUD, `state` and
  /// the settings remedy offered in the menu bar.
  func recordDeliveryFailure(
    _ error: Error,
    headline: String,
    remedy: DeliverySettingsRemedy?,
    finalText: String,
    session: ActiveSession
  ) async {
    let message = remedy.annotate(error.localizedDescription)
    session.errors.append(
      HistoryError(
        phase: .output,
        message: "Failed to deliver text",
        debugDescription: remedy.annotate(Self.historySafeDescription(of: error))
      )
    )
    hudManager.finishFailure(headline: headline, message: message)
    state = .failed(message)
    lastErrorMessage = message
    pendingDeliveryRemedy = remedy
    attachFailureDiagnostics(to: session)
    await historyManager.append(session.buildHistoryItem(finalText: finalText))
  }

  static func recordDeliveryWarning(_ note: String?, on session: ActiveSession) {
    guard let note else { return }
    session.events.append(
      HistoryEvent(kind: .outputDelivered, description: "Delivery warning: \(note)")
    )
  }

  static func retryDeliverySuccessMessage(note: String?) -> String {
    note.map { "Retry delivered — \($0)" } ?? "Retry Delivered"
  }

  /// Offers a remedy for a delivery made outside a recording session, such as
  /// pasting the last transcript.
  func offerDeliveryRemedy(_ remedy: DeliverySettingsRemedy?) {
    pendingDeliveryRemedy = remedy
  }

  /// Drops the offered remedy once the user has made that change some other
  /// way (Settings, System Settings), so the menu never offers a no-op.
  func reconcilePendingDeliveryRemedy() {
    guard let remedy = pendingDeliveryRemedy else { return }
    let satisfied = remedy.isSatisfied(
      configuration: DeliverySettingsRemedy.Configuration(settings: appSettings),
      accessibilityGranted: capture.permissions.status(for: .accessibility).isGranted
    )
    if satisfied {
      pendingDeliveryRemedy = nil
    }
  }

  /// Applies the setting change offered after the last delivery, then forgets it.
  func applyPendingDeliveryRemedy() {
    guard let remedy = pendingDeliveryRemedy else { return }
    remedy.apply(settings: appSettings, permissions: capture.permissions)
    pendingDeliveryRemedy = nil
  }
}
