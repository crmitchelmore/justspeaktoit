import AppKit
import Foundation
import SpeakCore

/// The last stage of a recorded dictation: finalise live insertion or deliver
/// the text once, record the session in History, and settle the HUD and the
/// host's state. A post-processing failure still delivers the unpolished text
/// but ends the session as failed.
@MainActor
final class SessionDelivery {
  /// How the final text reached (or was held back from) its destination.
  struct DeliveryOutcome {
    var target: TextOutputTarget?
    var warning: Error?
    var remedy: DeliverySettingsRemedy?
    var focusMovedToOtherApplication = false
  }

  private let settings: AppSettings
  private let permissions: PermissionsManager
  private let text: SessionTextServices
  private let history: HistoryManager
  private let hud: HUDManager

  init(
    settings: AppSettings,
    permissions: PermissionsManager,
    text: SessionTextServices,
    history: HistoryManager,
    hud: HUDManager
  ) {
    self.settings = settings
    self.permissions = permissions
    self.text = text
    self.history = history
    self.hud = hud
  }

  /// Inserts the final text, records the session in History and settles the
  /// HUD and the host's state, then releases the session.
  func deliver(
    _ finalText: String, postProcessingFailure: String?, for session: ActiveSession, host: SessionCompletionHost
  ) async {
    host.publish(.delivering)
    if postProcessingFailure == nil {
      self.hud.beginDelivering()
    }
    if let outcome = await self.insertFinalText(finalText, for: session, host: host) {
      await self.recordDelivered(
        finalText, outcome: outcome, postProcessingFailure: postProcessingFailure, for: session, host: host
      )
    }
    self.finishSessionTeardown(host: host)
  }

  /// Finalises live insertion or performs the one-shot output. Returns nil
  /// after recording a failed delivery.
  private func insertFinalText(
    _ finalText: String, for session: ActiveSession, host: SessionCompletionHost
  ) async -> DeliveryOutcome? {
    var liveFinalizationResult: LiveTextInserter.FinalizationResult = .deferred
    let liveTextInserter = self.text.liveTextInserter
    let usedStreamingInsertion = liveTextInserter.isActive && liveTextInserter.strategy == .rangedStreaming
    if liveTextInserter.isActive {
      liveFinalizationResult = liveTextInserter.applyPolishedFinal(finalText)
      liveTextInserter.end()
    }
    // Latency checkpoint: when the first character actually reached the target
    // app via live insertion (nil when the session never streamed text).
    session.firstInsertion = liveTextInserter.firstInsertionAt

    switch liveFinalizationResult {
    case .applied:
      session.outputMethod = .accessibility
      host.recordInsertion(
        of: liveTextInserter.insertedText,
        range: liveTextInserter.lastInsertedRange,
        target: session.outputTarget
      )
      return DeliveryOutcome(target: session.outputTarget)
    case .deferred, .redirected, .clipboard:
      return await self.deliverOneShot(finalText, after: liveFinalizationResult, for: session, host: host)
    case .failed(let error):
      let remedy = DeliverySettingsRemedy.forLiveInsertionFailure(
        error,
        usedStreamingInsertion: usedStreamingInsertion,
        configuration: DeliverySettingsRemedy.Configuration(settings: self.settings)
      )
      await host.recordDeliveryFailure(
        error, headline: "Delivery failed", remedy: remedy, finalText: finalText, session: session
      )
      return nil
    }
  }

  /// Delivers through `SmartTextOutput` when live insertion did not finish
  /// the job. Returns nil after recording a failed delivery.
  private func deliverOneShot(
    _ finalText: String,
    after liveFinalizationResult: LiveTextInserter.FinalizationResult,
    for session: ActiveSession,
    host: SessionCompletionHost
  ) async -> DeliveryOutcome? {
    let output = SmartTextOutput(permissionsManager: self.permissions, appSettings: self.settings)
    let outputResult: TextOutputResult
    switch liveFinalizationResult {
    case .redirected(let target): outputResult = output.output(text: finalText, target: target)
    case .clipboard(let error): outputResult = SmartTextOutput.keepOnClipboard(text: finalText, error: error)
    default: outputResult = output.output(text: finalText, target: session.outputTarget)
    }
    let deliveryTarget = outputResult.redirectedTarget ?? session.outputTarget
    let deliveryRemedy = MainManager.remedy(forDelivery: outputResult, settings: self.settings)
    session.outputMethod = outputResult.method
    if let error = outputResult.error {
      await host.recordDeliveryFailure(
        error, headline: MainManager.deliveryFailureHeadline(for: error), remedy: deliveryRemedy,
        finalText: finalText, session: session
      )
      return nil
    }
    host.recordInsertion(of: finalText, range: outputResult.insertedRange, target: deliveryTarget)
    return DeliveryOutcome(
      target: deliveryTarget,
      warning: outputResult.warning,
      remedy: deliveryRemedy,
      focusMovedToOtherApplication: outputResult.focusMovedToOtherApplication
    )
  }

  private func recordDelivered(
    _ finalText: String,
    outcome: DeliveryOutcome,
    postProcessingFailure: String?,
    for session: ActiveSession,
    host: SessionCompletionHost
  ) async {
    let focusedElement = outcome.target?.focusedElement ?? Self.focusedElement()
    let appName = outcome.target?.applicationName
      ?? NSWorkspace.shared.frontmostApplication?.localizedName
    // A warning means delivery proceeded without proving the current field.
    // Do not associate Voice Edit/correction tracking with the stale capture.
    if outcome.warning == nil {
      self.text.autoCorrectionTracker.startMonitoring(
        insertedText: finalText,
        element: focusedElement,
        app: appName
      )
    }

    session.outputDelivered = Date()

    session.events.append(
      HistoryEvent(kind: .outputDelivered, description: "Output delivered successfully")
    )
    let deliveryNote = Self.deliveryNote(for: outcome, destination: appName, on: session)
    session.destination = appName
    session.lexiconContext = PersonalLexiconContext.inferred(for: finalText, destination: appName)
    if let summary = session.personalCorrections {
      session.personalCorrections = summary.updatingContext(
        tags: Array(session.lexiconContext.tags).sorted(),
        destination: appName
      )
    }
    let historyItem = session.buildHistoryItem(finalText: finalText)
    await self.history.append(historyItem)
    if let postProcessingFailure {
      host.publishFailure(postProcessingFailure)
      return
    }
    self.finishDeliverySuccess(historyItem, outcome: outcome, note: deliveryNote, for: session, host: host)
  }

  /// The note shown for a delivery that succeeded but not quite as expected,
  /// also recorded on the session without naming the app: History can be
  /// exported to a public issue.
  private static func deliveryNote(
    for outcome: DeliveryOutcome, destination: String?, on session: ActiveSession
  ) -> String? {
    MainManager.recordDeliveryWarning(
      MainManager.deliveryNote(
        warning: outcome.warning,
        focusMovedToOtherApplication: outcome.focusMovedToOtherApplication,
        destination: nil,
        remedy: outcome.remedy
      ),
      on: session
    )
    return MainManager.deliveryNote(
      warning: outcome.warning,
      focusMovedToOtherApplication: outcome.focusMovedToOtherApplication,
      destination: destination,
      remedy: outcome.remedy
    )
  }

  private func finishDeliverySuccess(
    _ historyItem: HistoryItem,
    outcome: DeliveryOutcome,
    note deliveryNote: String?,
    for session: ActiveSession,
    host: SessionCompletionHost
  ) {
    host.offerDeliveryRemedy(outcome.remedy)
    self.hud.finishSuccess(
      message: MainManager.deliverySuccessMessage(
        note: deliveryNote,
        stopRequested: session.stopRequested,
        delivered: session.outputDelivered
      ),
      displayDuration: deliveryNote == nil ? nil : self.hud.failureDisplayDuration
    )
    host.publish(.completed(historyItem))
    if session.isLocalAutomationCapture {
      self.history.finishAutomationCapture(id: session.id, item: historyItem)
    }
    host.captureFirstTranscriptionSucceededIfNeeded(session: session)
  }

  /// Resets live polish and insertion and releases the session.
  private func finishSessionTeardown(host: SessionCompletionHost) {
    self.text.livePolish.reset()
    self.text.liveTextInserter.reset()
    host.releaseActiveSession()
  }

  private static func focusedElement() -> AXUIElement? {
    let systemWideElement = AXUIElementCreateSystemWide()
    var rawFocused: CFTypeRef?
    let copyStatus = AXUIElementCopyAttributeValue(
      systemWideElement, kAXFocusedUIElementAttribute as CFString, &rawFocused
    )
    guard copyStatus == .success, let rawFocused else { return nil }
    return unsafeBitCast(rawFocused, to: AXUIElement.self)
  }
}
