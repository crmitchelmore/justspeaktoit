import AppKit
import Foundation
import SpeakCore

/// The stages a recorded dictation goes through after the stop: transcribe,
/// apply voice commands and the personal lexicon, post-process, deliver.
/// Each stage returns early (false / nil) when the session was abandoned
/// while it was suspended, so a newer session is never touched.
extension MainManager {
  /// Outcome of the post-processing stage: the text to deliver and, when the
  /// model failed, the message shown instead of a success.
  struct PostProcessingStep {
    var text: String
    var failureMessage: String?
  }

  /// Drains the live provider and records its transcript.
  func finishLiveTranscription(for session: ActiveSession) async throws -> Bool {
    session.transcriptionStarted = Date()
    let result = try await transcriptionManager.stopLiveTranscription()
    guard sessionProcessingShouldContinue(session) else { return false }
    session.transcriptionEnded = Date()
    session.transcriptionResult = result
    session.modelsUsed.insert(result.modelIdentifier)
    session.modelUsages.append(ModelUsage(modelIdentifier: result.modelIdentifier, phase: .transcriptionLive))
    session.events.append(
      HistoryEvent(kind: .transcriptionReceived, description: "Live transcription complete")
    )
    if let cost = result.cost {
      session.recordCostFragment(cost)
    }
    if let exchange = SessionNetworkExchanges.liveTranscription(result) {
      session.networkExchanges.append(exchange)
    }
    return true
  }

  /// Transcribes the recorded file with the batch or local model.
  func transcribeRecording(_ summary: RecordingSummary, for session: ActiveSession) async throws -> Bool {
    hudManager.beginTranscribing(subheadline: rawTranscriptionSubheadline())
    session.transcriptionStarted = Date()
    if appSettings.transcriptionMode == .batchRemote {
      guard
        await ensureBatchAPIKeyAvailable(
          for: session,
          message:
            "Batch transcription requires an OpenRouter API key. Add one in Settings › API Keys."
        )
      else {
        return false
      }
    }
    let result = try await transcriptionManager.transcribeFile(at: summary.url) { [weak self] receipt in
      Self.retainBatchDiagnostic(receipt, for: session, activeSession: self?.activeSession)
    }
    guard sessionProcessingShouldContinue(session) else { return false }
    recordFileTranscription(
      result,
      fileName: summary.url.lastPathComponent,
      isLocal: appSettings.transcriptionMode == .localModel,
      on: session
    )
    return true
  }

  /// Records a batch or local file transcription: result, model usage, its
  /// network row and cost.
  func recordFileTranscription(
    _ result: TranscriptionResult,
    fileName: String,
    isLocal: Bool,
    on session: ActiveSession
  ) {
    session.transcriptionEnded = Date()
    session.transcriptionResult = result
    session.modelsUsed.insert(result.modelIdentifier)
    session.modelUsages.append(
      ModelUsage(modelIdentifier: result.modelIdentifier, phase: isLocal ? .transcriptionLocal : .transcriptionBatch)
    )
    session.events.append(
      HistoryEvent(
        kind: .transcriptionReceived,
        description: isLocal ? "Local model transcription complete" : "Batch transcription complete"
      )
    )
    if let exchange = SessionNetworkExchanges.fileTranscription(result, fileName: fileName, isLocal: isLocal) {
      session.networkExchanges.append(exchange)
    }
    if let cost = result.cost {
      session.recordCostFragment(cost)
    }
  }

  /// Runs voice commands (e.g., "copy pasta" → clipboard content) and the
  /// personal lexicon over the raw transcript, recording what changed.
  func applyVoiceCommandsAndLexicon(to rawText: String, for session: ActiveSession) -> String {
    let baseText = textProcessor.process(rawText)
    let lexiconContext = makeLexiconContext(for: baseText, destination: nil)
    let corrections = personalLexicon.apply(to: baseText, context: lexiconContext)
    session.personalCorrections = PersonalLexiconHistorySummary(
      applied: corrections.applied,
      suggestions: corrections.suggestions,
      contextTags: Array(lexiconContext.tags).sorted(),
      destinationApplication: lexiconContext.destinationApplication
    )
    session.lexiconContext = lexiconContext
    return corrections.transformedText
  }

  /// Polishes the text when the speed mode asks for it. A model failure still
  /// delivers the unpolished text and offers a retry.
  func postProcessIfNeeded(_ text: String, for session: ActiveSession) async -> PostProcessingStep? {
    guard shouldRunPostProcessing() else { return PostProcessingStep(text: text) }
    hudManager.beginPostProcessing()
    session.postProcessingStarted = Date()
    guard
      await ensurePostProcessingAPIKeyAvailable(
        for: session,
        message:
          "Post-processing requires an OpenRouter API key. Add one in Settings › API Keys."
      )
    else {
      return nil
    }
    let resolvedPostProcessingModel =
      ModelCatalog.resolvedPostProcessingModel(appSettings.postProcessingModel)
    let outcomeResult = await postProcessingManager.process(
      rawText: text,
      context: session.lexiconContext,
      corrections: session.personalCorrections,
      onStreamingUpdate: { [weak self] accumulatedText in
        Task { @MainActor in
          self?.hudManager.updateStreamingText(accumulatedText)
        }
      },
      onDiagnostic: { [weak self] in
        Self.retainPostProcessingDiagnostic($0, for: session, activeSession: self?.activeSession)
      }
    )
    guard sessionProcessingShouldContinue(session) else { return nil }
    switch outcomeResult {
    case .success(let outcome):
      recordPostProcessingSuccess(
        outcome,
        model: resolvedPostProcessingModel,
        input: text,
        description: outcome.response == nil ? "Post-processing complete (streamed)" : "Post-processing complete",
        on: session
      )
      return PostProcessingStep(text: outcome.processed)
    case .failure(let error):
      let friendly = recordPostProcessingFailure(error, model: resolvedPostProcessingModel, on: session)
      attachFailureDiagnostics(to: session)
      let offersRetry = retryStore.offer(for: session)
      hudManager.finishFailure(headline: "Post-processing failed", message: friendly, showRetryHint: offersRetry)
      return PostProcessingStep(text: text, failureMessage: friendly)
    }
  }

  /// How the final text reached (or was held back from) its destination.
  struct DeliveryOutcome {
    var target: TextOutputTarget?
    var warning: Error?
    var remedy: DeliverySettingsRemedy?
    var focusMovedToOtherApplication = false
  }

  /// Inserts the final text, records the session in History and settles the
  /// HUD and `state`.
  func deliver(_ finalText: String, postProcessingFailure: String?, for session: ActiveSession) async {
    state = .delivering
    if postProcessingFailure == nil {
      hudManager.beginDelivering()
    }
    guard let outcome = await insertFinalText(finalText, for: session) else {
      finishSessionTeardown()
      return
    }
    await recordDelivered(finalText, outcome: outcome, postProcessingFailure: postProcessingFailure, for: session)
    finishSessionTeardown()
  }

  /// Finalises live insertion or performs the one-shot output. Returns nil
  /// after recording a failed delivery.
  private func insertFinalText(_ finalText: String, for session: ActiveSession) async -> DeliveryOutcome? {
    var liveFinalizationResult: LiveTextInserter.FinalizationResult = .deferred
    let usedStreamingInsertion = liveTextInserter.isActive && liveTextInserter.strategy == .rangedStreaming
    if liveTextInserter.isActive {
      liveFinalizationResult = liveTextInserter.applyPolishedFinal(finalText)
      liveTextInserter.end()
    }
    // Latency checkpoint: when the first character actually reached the target
    // app via live insertion (nil when the session never streamed text).
    session.firstInsertion = self.liveTextInserter.firstInsertionAt

    switch liveFinalizationResult {
    case .applied:
      session.outputMethod = .accessibility
      recordInsertion(
        of: liveTextInserter.insertedText,
        range: liveTextInserter.lastInsertedRange,
        target: session.outputTarget
      )
      return DeliveryOutcome(target: session.outputTarget)
    case .deferred, .redirected, .clipboard:
      return await deliverOneShot(finalText, after: liveFinalizationResult, for: session)
    case .failed(let error):
      let remedy = DeliverySettingsRemedy.forLiveInsertionFailure(
        error,
        usedStreamingInsertion: usedStreamingInsertion,
        configuration: DeliverySettingsRemedy.Configuration(settings: appSettings)
      )
      await recordDeliveryFailure(
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
    for session: ActiveSession
  ) async -> DeliveryOutcome? {
    let output = SmartTextOutput(permissionsManager: permissionsManager, appSettings: appSettings)
    let outputResult: TextOutputResult
    switch liveFinalizationResult {
    case .redirected(let target): outputResult = output.output(text: finalText, target: target)
    case .clipboard(let error): outputResult = SmartTextOutput.keepOnClipboard(text: finalText, error: error)
    default: outputResult = output.output(text: finalText, target: session.outputTarget)
    }
    let deliveryTarget = outputResult.redirectedTarget ?? session.outputTarget
    let deliveryRemedy = remedy(forDelivery: outputResult)
    session.outputMethod = outputResult.method
    if let error = outputResult.error {
      await recordDeliveryFailure(
        error, headline: Self.deliveryFailureHeadline(for: error), remedy: deliveryRemedy,
        finalText: finalText, session: session
      )
      return nil
    }
    recordInsertion(of: finalText, range: outputResult.insertedRange, target: deliveryTarget)
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
    for session: ActiveSession
  ) async {
    let focusedElement = outcome.target?.focusedElement ?? getFocusedElement()
    let appName = outcome.target?.applicationName
      ?? NSWorkspace.shared.frontmostApplication?.localizedName
    // A warning means delivery proceeded without proving the current field.
    // Do not associate Voice Edit/correction tracking with the stale capture.
    if outcome.warning == nil {
      autoCorrectionTracker.startMonitoring(
        insertedText: finalText,
        element: focusedElement,
        app: appName
      )
    }

    session.outputDelivered = Date()

    session.events.append(
      HistoryEvent(kind: .outputDelivered, description: "Output delivered successfully")
    )
    let deliveryNote = deliveryNote(for: outcome, destination: appName, on: session)
    session.destination = appName
    session.lexiconContext = makeLexiconContext(for: finalText, destination: appName)
    if let summary = session.personalCorrections {
      session.personalCorrections = summary.updatingContext(
        tags: Array(session.lexiconContext.tags).sorted(),
        destination: appName
      )
    }
    let historyItem = session.buildHistoryItem(finalText: finalText)
    await historyManager.append(historyItem)
    if let postProcessingFailure {
      lastErrorMessage = postProcessingFailure
      state = .failed(postProcessingFailure)
      return
    }
    finishDeliverySuccess(historyItem, outcome: outcome, note: deliveryNote, for: session)
  }

  /// The note shown for a delivery that succeeded but not quite as expected,
  /// also recorded on the session without naming the app: History can be
  /// exported to a public issue.
  private func deliveryNote(for outcome: DeliveryOutcome, destination: String?, on session: ActiveSession) -> String? {
    recordDeliveryWarning(
      Self.deliveryNote(
        warning: outcome.warning,
        focusMovedToOtherApplication: outcome.focusMovedToOtherApplication,
        destination: nil,
        remedy: outcome.remedy
      ),
      on: session
    )
    return Self.deliveryNote(
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
    for session: ActiveSession
  ) {
    pendingDeliveryRemedy = outcome.remedy
    hudManager.finishSuccess(
      message: Self.deliverySuccessMessage(
        note: deliveryNote,
        stopRequested: session.stopRequested,
        delivered: session.outputDelivered
      ),
      displayDuration: deliveryNote == nil ? nil : hudManager.failureDisplayDuration
    )
    state = .completed(historyItem)
    if session.isLocalAutomationCapture {
      historyManager.finishAutomationCapture(id: session.id, item: historyItem)
    }
    captureFirstTranscriptionSucceededIfNeeded(session: session)
  }

  /// Records a successful polish: timings, model usage, its network row and cost.
  func recordPostProcessingSuccess(
    _ outcome: PostProcessingOutcome,
    model: String,
    input: String,
    description: String,
    on session: ActiveSession
  ) {
    session.postProcessingEnded = Date()
    session.postProcessingOutcome = outcome
    session.events.append(HistoryEvent(kind: .postProcessingReceived, description: description))
    session.modelsUsed.insert(model)
    session.modelUsages.append(ModelUsage(modelIdentifier: model, phase: .postProcessing))
    guard let response = outcome.response else { return }
    if let payload = response.rawPayload {
      session.networkExchanges.append(
        SessionNetworkExchanges.postProcessing(
          model: model,
          requestPreview: postProcessingRequestPreview(systemPrompt: outcome.systemPrompt, rawText: input),
          payload: payload
        )
      )
    }
    if let cost = response.cost {
      session.recordCostFragment(cost)
    }
  }

  /// Records a failed polish in History and returns the message to show.
  func recordPostProcessingFailure(_ error: Error, model: String, on session: ActiveSession) -> String {
    session.postProcessingEnded = Date()
    let friendly = Self.friendlyPostProcessingMessage(for: error, modelIdentifier: model)
    session.errors.append(
      HistoryError(
        phase: .postProcessing,
        message: friendly,
        debugDescription: error.localizedDescription
      )
    )
    session.events.append(HistoryEvent(kind: .error, description: friendly))
    return friendly
  }

  /// Resets live polish and insertion and releases the session.
  func finishSessionTeardown() {
    livePolishManager.reset()
    liveTextInserter.reset()
    activeSession = nil
  }
}
