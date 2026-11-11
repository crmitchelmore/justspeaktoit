import AppKit
import Foundation
import SpeakCore

/// Retries post-processing for the transcript kept by `PostProcessingRetryStore`
/// and delivers the result to the field captured at retry time.
extension MainManager {
  func performRetryPostProcessing(with retryData: PostProcessingRetryStore.Entry) async {
    state = .processing
    lastErrorMessage = nil
    pendingDeliveryRemedy = nil
    hudManager.beginPostProcessing()

    let session = makeRetrySession(for: retryData)
    activeSession = session

    let finalText = retryInputText(for: retryData)

    guard
      await ensurePostProcessingAPIKeyAvailable(
        for: session,
        message: "Post-processing requires an OpenRouter API key. Add one in Settings › API Keys."
      )
    else {
      return
    }

    let resolvedPostProcessingModel =
      ModelCatalog.resolvedPostProcessingModel(appSettings.postProcessingModel)

    session.postProcessingStarted = Date()
    let outcomeResult = await postProcessingManager.process(
      rawText: finalText,
      context: retryData.lexiconContext,
      corrections: retryData.personalCorrections,
      onDiagnostic: { [weak self] in
        Self.retainPostProcessingDiagnostic($0, for: session, activeSession: self?.activeSession)
      }
    )

    switch outcomeResult {
    case .success(let outcome):
      recordPostProcessingSuccess(
        outcome,
        model: resolvedPostProcessingModel,
        input: finalText,
        description: "Retry post-processing complete",
        on: session
      )
      await deliverRetry(outcome.processed, for: session)
    case .failure(let error):
      let friendly = recordPostProcessingFailure(error, model: resolvedPostProcessingModel, on: session)
      hudManager.finishFailure(headline: "Retry post-processing failed", message: friendly, showRetryHint: true)
      state = .failed(friendly)
      lastErrorMessage = friendly
      attachFailureDiagnostics(to: session)
      let historyItem = session.buildHistoryItem(finalText: finalText)
      await historyManager.append(historyItem)
    }

    activeSession = nil
  }

  /// The retried transcript, with the personal lexicon reapplied when the
  /// original session applied it.
  private func retryInputText(for retryData: PostProcessingRetryStore.Entry) -> String {
    let baseText = retryData.transcriptionResult.text
    guard retryData.personalCorrections != nil else { return baseText }
    return personalLexicon.apply(to: baseText, context: retryData.lexiconContext).transformedText
  }

  private func makeRetrySession(for retryData: PostProcessingRetryStore.Entry) -> ActiveSession {
    let session = ActiveSession(gesture: .uiButton, hotKeyDescription: appSettings.selectedHotKey.displayString)
    session.outputTarget = TextOutputTarget.capture()
    session.diagnosticContext = makeHistoryDiagnosticContext()
    session.transcriptionResult = retryData.transcriptionResult
    session.recordingSummary = retryData.recordingSummary
    session.personalCorrections = retryData.personalCorrections
    session.lexiconContext = retryData.lexiconContext
    session.events.append(
      HistoryEvent(kind: .postProcessingSubmitted, description: "Retry post-processing requested")
    )
    return session
  }

  private func deliverRetry(_ finalText: String, for session: ActiveSession) async {
    state = .delivering
    hudManager.beginDelivering()
    let output = SmartTextOutput(permissionsManager: permissionsManager, appSettings: appSettings)
    let outputResult = output.output(text: finalText, target: session.outputTarget)
    let deliveryTarget = outputResult.redirectedTarget ?? session.outputTarget
    let deliveryRemedy = remedy(forDelivery: outputResult)
    session.outputMethod = outputResult.method
    session.outputDelivered = Date()

    if let error = outputResult.error {
      await recordDeliveryFailure(
        error, headline: Self.deliveryFailureHeadline(for: error), remedy: deliveryRemedy,
        finalText: finalText, session: session
      )
      return
    }
    recordInsertion(of: finalText, range: outputResult.insertedRange, target: deliveryTarget)

    let appName = deliveryTarget?.applicationName
      ?? NSWorkspace.shared.frontmostApplication?.localizedName
    let deliveryNote = Self.deliveryNote(
      warning: outputResult.warning,
      focusMovedToOtherApplication: outputResult.focusMovedToOtherApplication,
      destination: appName,
      remedy: deliveryRemedy
    )
    recordDeliveryWarning(
      Self.deliveryNote(
        warning: outputResult.warning,
        focusMovedToOtherApplication: outputResult.focusMovedToOtherApplication,
        destination: nil,
        remedy: deliveryRemedy
      ),
      on: session
    )
    session.events.append(
      HistoryEvent(kind: .outputDelivered, description: "Retry output delivered successfully")
    )
    session.destination = appName
    let historyItem = session.buildHistoryItem(finalText: finalText)
    await historyManager.append(historyItem)
    retryStore.clear()
    pendingDeliveryRemedy = deliveryRemedy
    hudManager.finishSuccess(
      message: Self.retryDeliverySuccessMessage(note: deliveryNote),
      displayDuration: deliveryNote == nil ? nil : hudManager.failureDisplayDuration
    )
    state = .completed(historyItem)
  }
}
