import AppKit
import Foundation
import SpeakCore

/// The façade state the reprocessing flows publish. `MainManager` is the only host.
@MainActor
protocol ReprocessingHost: AnyObject {
  var activeSession: ActiveSession? { get }
  /// Makes `session` the active one, so no dictation can start over it.
  func adopt(_ session: ActiveSession)
  /// Clears the active session, retiring it like any other session.
  func releaseActiveSession()
  func publish(_ state: MainManager.State)
  /// Publishes `.failed(message)` and `lastErrorMessage`.
  func publishFailure(_ message: String)
  /// Clears the last error and the offered delivery remedy.
  func clearDeliveryFeedback()
  func makeDiagnosticContext() -> HistoryDiagnosticContext
  /// See `MainManager.handleMissingAPIKey`.
  func failForMissingAPIKey(_ session: ActiveSession, phase: HistoryError.Phase, message: String) async
  /// See `MainManager.recordDeliveryFailure`.
  func recordDeliveryFailure(
    _ error: Error, headline: String, remedy: DeliverySettingsRemedy?, finalText: String, session: ActiveSession
  ) async
  func recordInsertion(of text: String, range: VoiceEditTextRange?, target: TextOutputTarget?)
  /// A retry delivered: forget the retry and offer `remedy`, if any.
  func completeRetryDelivery(remedy: DeliverySettingsRemedy?)
}

/// Re-runs work for text that already exists, without a recording:
/// re-transcribing a History item's audio (or an imported file) into a new
/// History entry, and retrying post-processing for the transcript that
/// `PostProcessingRetryStore` kept, delivered to the field captured at retry
/// time. Each run owns its own `ActiveSession` from adoption to release.
@MainActor
final class ReprocessingCoordinator {
  weak var host: ReprocessingHost?

  private let settings: AppSettings
  private let permissions: PermissionsManager
  private let transcription: TranscriptionManager
  private let text: SessionTextServices
  private let history: HistoryManager
  private let hud: HUDManager

  private static let missingPostProcessingKeyMessage =
    "Post-processing requires an OpenRouter API key. Add one in Settings › API Keys."

  init(
    settings: AppSettings,
    permissions: PermissionsManager,
    transcription: TranscriptionManager,
    text: SessionTextServices,
    history: HistoryManager,
    hud: HUDManager
  ) {
    self.settings = settings
    self.permissions = permissions
    self.transcription = transcription
    self.text = text
    self.history = history
    self.hud = hud
  }

  // MARK: - Reprocess a History item

  func reprocess(_ item: HistoryItem) async {
    guard let host, host.activeSession == nil else { return }
    guard let url = item.audioFileURL else { return }

    host.publish(.processing)
    hud.beginTranscribing(subheadline: MainManager.rawTranscriptionSubheadline(settings: settings))

    let session = ActiveSession(gesture: .uiButton, hotKeyDescription: item.trigger.hotKeyDescription)
    session.diagnosticContext = host.makeDiagnosticContext()
    host.adopt(session)
    recordReprocessRequest(of: item, audioURL: url, on: session)

    do {
      session.transcriptionStarted = Date()
      let isLocalTranscription = settings.transcriptionMode == .localModel
      session.events.append(
        HistoryEvent(
          kind: .transcriptionSubmitted,
          description: isLocalTranscription ? "Submitting to local model" : "Submitting to batch model"
        )
      )
      let result = try await transcription.transcribeFile(at: url) { [weak host] receipt in
        MainManager.retainBatchDiagnostic(receipt, for: session, activeSession: host?.activeSession)
      }
      session.recordFileTranscription(result, fileName: url.lastPathComponent, isLocal: isLocalTranscription)

      let correctedText = text.applyVoiceCommandsAndLexicon(to: result.text, for: session)
      guard let finalText = await postProcessReprocessedText(correctedText, for: session) else { return }

      hud.beginDelivering()
      hud.finishSuccess(message: "Reprocessed")
      session.events.append(HistoryEvent(kind: .outputDelivered, description: "Reprocess stored in history"))
      session.outputMethod = .none
      let historyItem = session.buildHistoryItem(finalText: finalText, source: item.source)
      host.publish(.completed(historyItem))
      await history.append(historyItem)
      host.releaseActiveSession()
    } catch {
      await recordReprocessFailure(error, of: item, on: session, host: host)
    }
  }

  private func recordReprocessFailure(
    _ error: Error,
    of item: HistoryItem,
    on session: ActiveSession,
    host: ReprocessingHost
  ) async {
    session.errors.append(
      HistoryError(phase: .transcription, message: "Reprocess failed", debugDescription: error.localizedDescription)
    )
    hud.finishFailure(message: error.localizedDescription)
    host.publish(.failed(error.localizedDescription))
    MainManager.attachFailureDiagnostics(to: session) { host.makeDiagnosticContext() }
    let historyItem = session.buildHistoryItem(finalText: session.transcriptionResult?.text, source: item.source)
    await history.append(historyItem)
    host.releaseActiveSession()
  }

  private func recordReprocessRequest(of item: HistoryItem, audioURL url: URL, on session: ActiveSession) {
    let summary = RecordingSummary.inspecting(url, fallbackDuration: item.recordingDuration)
    session.recordingSummary = summary
    session.recordingStarted = summary.startedAt
    session.recordingEnded = summary.startedAt.addingTimeInterval(summary.duration)
    let reprocessDescription = item.source == .importedFile
      ? "Import requested: \(url.lastPathComponent)"
      : "Reprocess requested"
    session.events.append(HistoryEvent(kind: .recordingStarted, description: reprocessDescription))
  }

  /// Polishes reprocessed text when the speed mode asks for it. A model
  /// failure keeps the unpolished text; nil means the session was abandoned
  /// for a missing API key.
  private func postProcessReprocessedText(_ input: String, for session: ActiveSession) async -> String? {
    guard MainManager.shouldRunPostProcessing(settings: settings) else { return input }
    hud.beginPostProcessing()
    session.postProcessingStarted = Date()
    guard await ensurePostProcessingAPIKey(for: session) else { return nil }
    session.events.append(HistoryEvent(kind: .postProcessingSubmitted, description: "Sending to post-processor"))
    let model = settings.postProcessingModel
    let outcomeResult = await text.postProcessing.process(
      rawText: input,
      context: session.lexiconContext,
      corrections: session.personalCorrections,
      onStreamingUpdate: { [weak hud] accumulatedText in
        Task { @MainActor in
          hud?.updateStreamingText(accumulatedText)
        }
      },
      onDiagnostic: { [weak host] in
        MainManager.retainPostProcessingDiagnostic($0, for: session, activeSession: host?.activeSession)
      }
    )
    switch outcomeResult {
    case .success(let outcome):
      // Unlike a live session this names the configured model as stored, and
      // skips usage when none is configured.
      session.postProcessingEnded = Date()
      session.postProcessingOutcome = outcome
      session.events.append(
        HistoryEvent(
          kind: .postProcessingReceived,
          description: outcome.response == nil ? "Post-processing complete (streamed)" : "Post-processing complete"
        )
      )
      session.recordPostProcessingResponse(of: outcome, model: model, input: input)
      if !model.isEmpty {
        session.modelsUsed.insert(model)
        session.modelUsages.append(ModelUsage(modelIdentifier: model, phase: .postProcessing))
      }
      return outcome.processed
    case .failure(let error):
      let friendly = MainManager.friendlyPostProcessingMessage(for: error, modelIdentifier: model)
      session.errors.append(
        HistoryError(phase: .postProcessing, message: friendly, debugDescription: error.localizedDescription)
      )
      session.events.append(HistoryEvent(kind: .error, description: friendly))
      return input
    }
  }

  // MARK: - Retry post-processing

  func retryPostProcessing(with retryData: PostProcessingRetryStore.Entry) async {
    guard let host else { return }
    host.publish(.processing)
    host.clearDeliveryFeedback()
    hud.beginPostProcessing()

    let session = makeRetrySession(for: retryData, host: host)
    host.adopt(session)

    let finalText = text.retryInputText(for: retryData)
    guard await ensurePostProcessingAPIKey(for: session) else { return }

    let model = ModelCatalog.resolvedPostProcessingModel(settings.postProcessingModel)
    session.postProcessingStarted = Date()
    let outcomeResult = await text.postProcessing.process(
      rawText: finalText,
      context: retryData.lexiconContext,
      corrections: retryData.personalCorrections,
      onDiagnostic: { [weak host] in
        MainManager.retainPostProcessingDiagnostic($0, for: session, activeSession: host?.activeSession)
      }
    )

    switch outcomeResult {
    case .success(let outcome):
      session.recordPostProcessingSuccess(
        outcome, model: model, input: finalText, description: "Retry post-processing complete"
      )
      await deliverRetry(outcome.processed, for: session, host: host)
    case .failure(let error):
      let friendly = session.recordPostProcessingFailure(error, model: model)
      hud.finishFailure(headline: "Retry post-processing failed", message: friendly, showRetryHint: true)
      host.publishFailure(friendly)
      MainManager.attachFailureDiagnostics(to: session) { host.makeDiagnosticContext() }
      await history.append(session.buildHistoryItem(finalText: finalText))
    }

    host.releaseActiveSession()
  }

  private func makeRetrySession(
    for retryData: PostProcessingRetryStore.Entry,
    host: ReprocessingHost
  ) -> ActiveSession {
    let session = ActiveSession(gesture: .uiButton, hotKeyDescription: settings.selectedHotKey.displayString)
    session.outputTarget = TextOutputTarget.capture()
    session.diagnosticContext = host.makeDiagnosticContext()
    session.transcriptionResult = retryData.transcriptionResult
    session.recordingSummary = retryData.recordingSummary
    session.personalCorrections = retryData.personalCorrections
    session.lexiconContext = retryData.lexiconContext
    session.events.append(
      HistoryEvent(kind: .postProcessingSubmitted, description: "Retry post-processing requested")
    )
    return session
  }

  private func deliverRetry(_ finalText: String, for session: ActiveSession, host: ReprocessingHost) async {
    host.publish(.delivering)
    hud.beginDelivering()
    let output = SmartTextOutput(permissionsManager: permissions, appSettings: settings)
    let outputResult = output.output(text: finalText, target: session.outputTarget)
    let deliveryTarget = outputResult.redirectedTarget ?? session.outputTarget
    let deliveryRemedy = MainManager.remedy(forDelivery: outputResult, settings: settings)
    session.outputMethod = outputResult.method
    session.outputDelivered = Date()

    if let error = outputResult.error {
      await host.recordDeliveryFailure(
        error, headline: MainManager.deliveryFailureHeadline(for: error), remedy: deliveryRemedy,
        finalText: finalText, session: session
      )
      return
    }
    host.recordInsertion(of: finalText, range: outputResult.insertedRange, target: deliveryTarget)

    let appName = deliveryTarget?.applicationName
      ?? NSWorkspace.shared.frontmostApplication?.localizedName
    let deliveryNote = MainManager.deliveryNote(
      warning: outputResult.warning,
      focusMovedToOtherApplication: outputResult.focusMovedToOtherApplication,
      destination: appName,
      remedy: deliveryRemedy
    )
    MainManager.recordDeliveryWarning(
      MainManager.deliveryNote(
        warning: outputResult.warning,
        focusMovedToOtherApplication: outputResult.focusMovedToOtherApplication,
        destination: nil,
        remedy: deliveryRemedy
      ),
      on: session
    )
    session.events.append(HistoryEvent(kind: .outputDelivered, description: "Retry output delivered successfully"))
    session.destination = appName
    let historyItem = session.buildHistoryItem(finalText: finalText)
    await history.append(historyItem)
    host.completeRetryDelivery(remedy: deliveryRemedy)
    hud.finishSuccess(
      message: MainManager.retryDeliverySuccessMessage(note: deliveryNote),
      displayDuration: deliveryNote == nil ? nil : hud.failureDisplayDuration
    )
    host.publish(.completed(historyItem))
  }

  private func ensurePostProcessingAPIKey(for session: ActiveSession) async -> Bool {
    guard await text.postProcessing.hasRequiredAPIKey() else {
      await host?.failForMissingAPIKey(session, phase: .postProcessing, message: Self.missingPostProcessingKeyMessage)
      return false
    }
    return true
  }
}
