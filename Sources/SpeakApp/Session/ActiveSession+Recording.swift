import AVFoundation
import Foundation
import SpeakCore

/// What a session records about each stage it ran. Pure session mutations, so
/// the stop path and the reprocessing coordinator record the same way.
@MainActor
extension ActiveSession {
  /// Records a batch or local file transcription: result, model usage, its
  /// network row and cost.
  func recordFileTranscription(_ result: TranscriptionResult, fileName: String, isLocal: Bool) {
    transcriptionEnded = Date()
    transcriptionResult = result
    modelsUsed.insert(result.modelIdentifier)
    modelUsages.append(
      ModelUsage(modelIdentifier: result.modelIdentifier, phase: isLocal ? .transcriptionLocal : .transcriptionBatch)
    )
    events.append(
      HistoryEvent(
        kind: .transcriptionReceived,
        description: isLocal ? "Local model transcription complete" : "Batch transcription complete"
      )
    )
    if let exchange = SessionNetworkExchanges.fileTranscription(result, fileName: fileName, isLocal: isLocal) {
      networkExchanges.append(exchange)
    }
    if let cost = result.cost {
      recordCostFragment(cost)
    }
  }

  /// Records a successful polish: timings, model usage, its network row and cost.
  func recordPostProcessingSuccess(
    _ outcome: PostProcessingOutcome,
    model: String,
    input: String,
    description: String
  ) {
    postProcessingEnded = Date()
    postProcessingOutcome = outcome
    events.append(HistoryEvent(kind: .postProcessingReceived, description: description))
    modelsUsed.insert(model)
    modelUsages.append(ModelUsage(modelIdentifier: model, phase: .postProcessing))
    recordPostProcessingResponse(of: outcome, model: model, input: input)
  }

  /// Records the polish response's network row and cost, when it has one.
  func recordPostProcessingResponse(of outcome: PostProcessingOutcome, model: String, input: String) {
    guard let response = outcome.response else { return }
    if let payload = response.rawPayload {
      networkExchanges.append(
        SessionNetworkExchanges.postProcessing(
          model: model,
          requestPreview: MainManager.postProcessingRequestPreview(systemPrompt: outcome.systemPrompt, rawText: input),
          payload: payload
        )
      )
    }
    if let cost = response.cost {
      recordCostFragment(cost)
    }
  }

  /// Records a failed polish in History and returns the message to show.
  func recordPostProcessingFailure(_ error: Error, model: String) -> String {
    postProcessingEnded = Date()
    let friendly = MainManager.friendlyPostProcessingMessage(for: error, modelIdentifier: model)
    errors.append(
      HistoryError(
        phase: .postProcessing,
        message: friendly,
        debugDescription: error.localizedDescription
      )
    )
    events.append(HistoryEvent(kind: .error, description: friendly))
    return friendly
  }
}

extension RecordingSummary {
  /// A summary for an audio file already on disk; the duration falls back to
  /// `fallbackDuration` when the file cannot be read.
  static func inspecting(_ url: URL, fallbackDuration: TimeInterval) -> RecordingSummary {
    let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
    let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let duration = (try? AVAudioPlayer(contentsOf: url).duration) ?? fallbackDuration
    let resolvedDuration = duration.isFinite && duration > 0 ? duration : fallbackDuration
    let startedAt = (attributes[.creationDate] as? Date) ?? Date()
    return RecordingSummary(
      id: UUID(),
      url: url,
      startedAt: startedAt,
      duration: resolvedDuration,
      fileSize: fileSize
    )
  }
}
