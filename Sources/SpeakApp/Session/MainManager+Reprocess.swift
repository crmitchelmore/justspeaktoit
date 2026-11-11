import Foundation
import SpeakCore

/// Re-transcribes a History item's audio (or an imported file) and stores the
/// result as a new History entry without delivering it anywhere.
extension MainManager {
  func reprocessHistoryItem(_ item: HistoryItem) async {
    guard activeSession == nil else { return }
    guard let url = item.audioFileURL else { return }

    state = .processing
    hudManager.beginTranscribing(subheadline: rawTranscriptionSubheadline())

    let session = ActiveSession(
      gesture: .uiButton, hotKeyDescription: item.trigger.hotKeyDescription)
    session.diagnosticContext = makeHistoryDiagnosticContext()
    activeSession = session
    recordReprocessRequest(of: item, audioURL: url, on: session)

    do {
      session.transcriptionStarted = Date()
      let isLocalTranscription = appSettings.transcriptionMode == .localModel
      session.events.append(
        HistoryEvent(
          kind: .transcriptionSubmitted,
          description: isLocalTranscription ? "Submitting to local model" : "Submitting to batch model"
        )
      )
      let result = try await transcriptionManager.transcribeFile(at: url) { [weak self] receipt in
        Self.retainBatchDiagnostic(receipt, for: session, activeSession: self?.activeSession)
      }
      recordFileTranscription(result, fileName: url.lastPathComponent, isLocal: isLocalTranscription, on: session)

      let correctedText = applyVoiceCommandsAndLexicon(to: result.text, for: session)
      guard let finalText = await postProcessReprocessedText(correctedText, for: session) else { return }

      hudManager.beginDelivering()
      hudManager.finishSuccess(message: "Reprocessed")
      session.events.append(
        HistoryEvent(kind: .outputDelivered, description: "Reprocess stored in history")
      )
      session.outputMethod = .none
      let historyItem = session.buildHistoryItem(finalText: finalText, source: item.source)
      state = .completed(historyItem)
      await historyManager.append(historyItem)

      activeSession = nil
    } catch {
      await recordReprocessFailure(error, of: item, on: session)
    }
  }

  private func recordReprocessFailure(_ error: Error, of item: HistoryItem, on session: ActiveSession) async {
    session.errors.append(
      HistoryError(
        phase: .transcription,
        message: "Reprocess failed",
        debugDescription: error.localizedDescription
      )
    )
    hudManager.finishFailure(message: error.localizedDescription)
    state = .failed(error.localizedDescription)
    attachFailureDiagnostics(to: session)
    let historyItem = session.buildHistoryItem(
      finalText: session.transcriptionResult?.text,
      source: item.source
    )
    await historyManager.append(historyItem)
    activeSession = nil
  }

  private func recordReprocessRequest(of item: HistoryItem, audioURL url: URL, on session: ActiveSession) {
    let summary = makeRecordingSummary(from: url, fallbackDuration: item.recordingDuration)
    session.recordingSummary = summary
    session.recordingStarted = summary.startedAt
    session.recordingEnded = summary.startedAt.addingTimeInterval(summary.duration)
    let reprocessDescription = item.source == .importedFile
      ? "Import requested: \(url.lastPathComponent)"
      : "Reprocess requested"
    session.events.append(
      HistoryEvent(kind: .recordingStarted, description: reprocessDescription)
    )
  }

  /// Polishes reprocessed text when the speed mode asks for it. A model
  /// failure keeps the unpolished text; nil means the session was abandoned
  /// for a missing API key.
  private func postProcessReprocessedText(_ text: String, for session: ActiveSession) async -> String? {
    guard shouldRunPostProcessing() else { return text }
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
    session.events.append(
      HistoryEvent(kind: .postProcessingSubmitted, description: "Sending to post-processor")
    )
    let model = appSettings.postProcessingModel
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
    switch outcomeResult {
    case .success(let outcome):
      recordReprocessPolish(outcome, model: model, input: text, on: session)
      return outcome.processed
    case .failure(let error):
      let friendly = Self.friendlyPostProcessingMessage(for: error, modelIdentifier: model)
      session.errors.append(
        HistoryError(
          phase: .postProcessing,
          message: friendly,
          debugDescription: error.localizedDescription
        )
      )
      session.events.append(HistoryEvent(kind: .error, description: friendly))
      return text
    }
  }

  /// Records a reprocess polish. Unlike a live session this names the
  /// configured model as stored, and skips usage when none is configured.
  private func recordReprocessPolish(
    _ outcome: PostProcessingOutcome,
    model: String,
    input: String,
    on session: ActiveSession
  ) {
    session.postProcessingEnded = Date()
    session.postProcessingOutcome = outcome
    session.events.append(
      HistoryEvent(
        kind: .postProcessingReceived,
        description: outcome.response == nil ? "Post-processing complete (streamed)" : "Post-processing complete"
      )
    )
    if let response = outcome.response {
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
    if !model.isEmpty {
      session.modelsUsed.insert(model)
      session.modelUsages.append(ModelUsage(modelIdentifier: model, phase: .postProcessing))
    }
  }
}
