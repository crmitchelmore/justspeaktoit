import Foundation
import SpeakCore

/// The façade state the completion pipeline reads and publishes. `MainManager`
/// is the only host.
@MainActor
protocol SessionCompletionHost: AnyObject {
  var activeSession: ActiveSession? { get }
  /// See `MainManager.sessionProcessingShouldContinue(_:)`.
  func sessionProcessingShouldContinue(_ session: ActiveSession) -> Bool
  /// See `MainManager.handleMissingAPIKey`.
  func failForMissingAPIKey(_ session: ActiveSession, phase: HistoryError.Phase, message: String) async
  func attachFailureDiagnostics(to session: ActiveSession)
  func publish(_ state: MainManager.State)
  /// Publishes `.failed(message)` and `lastErrorMessage`.
  func publishFailure(_ message: String)
  /// Keeps the failed post-processing for retry; true when a retry is offered.
  func offerPostProcessingRetry(for session: ActiveSession) -> Bool
  /// See `MainManager.recordDeliveryFailure`.
  func recordDeliveryFailure(
    _ error: Error, headline: String, remedy: DeliverySettingsRemedy?, finalText: String, session: ActiveSession
  ) async
  func recordInsertion(of text: String, range: VoiceEditTextRange?, target: TextOutputTarget?)
  /// A delivery landed: offer `remedy`, if any, in the menu bar.
  func offerDeliveryRemedy(_ remedy: DeliverySettingsRemedy?)
  func captureFirstTranscriptionSucceededIfNeeded(session: ActiveSession)
  /// Clears the active session, retiring it like any other session.
  func releaseActiveSession()
}

/// Everything a recorded dictation goes through after the recorder stopped:
/// transcribe (draining the live provider or sending the file), apply voice
/// commands and the personal lexicon, post-process, then deliver and record
/// the session in History. Each stage returns early (false / nil) when the
/// session was abandoned while it was suspended, so a newer session is never
/// touched. `ReprocessingCoordinator` runs the equivalent flows without a
/// recording. Delivery itself belongs to `SessionDelivery`.
@MainActor
final class SessionCompletionPipeline {
  /// Outcome of the post-processing stage: the text to deliver and, when the
  /// model failed, the message shown instead of a success.
  struct PostProcessingStep {
    var text: String
    var failureMessage: String?
  }

  weak var host: SessionCompletionHost?

  private let settings: AppSettings
  private let transcription: TranscriptionManager
  private let text: SessionTextServices
  private let history: HistoryManager
  private let hud: HUDManager
  private let delivery: SessionDelivery

  static let missingBatchKeyMessage =
    "Batch transcription requires an OpenRouter API key. Add one in Settings › API Keys."
  static let missingPostProcessingKeyMessage =
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
    self.transcription = transcription
    self.text = text
    self.history = history
    self.hud = hud
    self.delivery = SessionDelivery(
      settings: settings, permissions: permissions, text: text, history: history, hud: hud
    )
  }

  /// Runs every stage for `session`, whose recording is `summary`.
  func complete(_ session: ActiveSession, recording summary: RecordingSummary, isStreaming: Bool) async throws {
    guard let host else { return }
    let transcribed = isStreaming
      ? try await self.finishLiveTranscription(for: session, host: host)
      : try await self.transcribeRecording(summary, for: session, host: host)
    guard transcribed else { return }
    let correctedText = self.text.applyVoiceCommandsAndLexicon(
      to: session.transcriptionResult?.text ?? "", for: session
    )
    guard let processed = await self.postProcessIfNeeded(correctedText, for: session, host: host) else { return }
    await self.delivery.deliver(
      processed.text, postProcessingFailure: processed.failureMessage, for: session, host: host
    )
  }

  static func rawTranscriptionSubheadline(settings: AppSettings) -> String {
    guard settings.transcriptionMode == .localModel else {
      return "Preparing raw transcript"
    }
    if LocalModelManager.shared.isModelLoaded(settings.localTranscriptionModel) {
      return "Transcribing locally on this Mac"
    }
    return "Loading local model and transcribing. First run can take a minute."
  }

  // MARK: - Transcription

  /// Drains the live provider and records its transcript.
  private func finishLiveTranscription(for session: ActiveSession, host: SessionCompletionHost) async throws -> Bool {
    session.transcriptionStarted = Date()
    let result = try await self.transcription.stopLiveTranscription()
    guard host.sessionProcessingShouldContinue(session) else { return false }
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
  private func transcribeRecording(
    _ summary: RecordingSummary, for session: ActiveSession, host: SessionCompletionHost
  ) async throws -> Bool {
    self.hud.beginTranscribing(subheadline: Self.rawTranscriptionSubheadline(settings: self.settings))
    session.transcriptionStarted = Date()
    if self.settings.transcriptionMode == .batchRemote {
      guard await self.transcription.hasValidBatchAPIKey() else {
        await host.failForMissingAPIKey(session, phase: .transcription, message: Self.missingBatchKeyMessage)
        return false
      }
    }
    let result = try await self.transcription.transcribeFile(at: summary.url) { [weak host] receipt in
      MainManager.retainBatchDiagnostic(receipt, for: session, activeSession: host?.activeSession)
    }
    guard host.sessionProcessingShouldContinue(session) else { return false }
    session.recordFileTranscription(
      result,
      fileName: summary.url.lastPathComponent,
      isLocal: self.settings.transcriptionMode == .localModel
    )
    return true
  }

  // MARK: - Post-processing

  /// Polishes the text when the speed mode asks for it. A model failure still
  /// delivers the unpolished text and offers a retry.
  private func postProcessIfNeeded(
    _ input: String, for session: ActiveSession, host: SessionCompletionHost
  ) async -> PostProcessingStep? {
    guard MainManager.shouldRunPostProcessing(settings: self.settings) else { return PostProcessingStep(text: input) }
    self.hud.beginPostProcessing()
    session.postProcessingStarted = Date()
    guard await self.text.postProcessing.hasRequiredAPIKey() else {
      await host.failForMissingAPIKey(
        session, phase: .postProcessing, message: Self.missingPostProcessingKeyMessage
      )
      return nil
    }
    let resolvedPostProcessingModel = ModelCatalog.resolvedPostProcessingModel(self.settings.postProcessingModel)
    let outcomeResult = await self.text.postProcessing.process(
      rawText: input,
      context: session.lexiconContext,
      corrections: session.personalCorrections,
      onStreamingUpdate: { [weak hud, weak host] accumulatedText in
        Task { @MainActor in
          // A chunk can land after this session was replaced; it must not
          // overwrite the replacement's HUD.
          guard host?.activeSession === session else { return }
          hud?.updateStreamingText(accumulatedText)
        }
      },
      onDiagnostic: { [weak host] in
        MainManager.retainPostProcessingDiagnostic($0, for: session, activeSession: host?.activeSession)
      }
    )
    guard host.sessionProcessingShouldContinue(session) else { return nil }
    switch outcomeResult {
    case .success(let outcome):
      session.recordPostProcessingSuccess(
        outcome,
        model: resolvedPostProcessingModel,
        input: input,
        description: outcome.response == nil ? "Post-processing complete (streamed)" : "Post-processing complete"
      )
      return PostProcessingStep(text: outcome.processed)
    case .failure(let error):
      let friendly = session.recordPostProcessingFailure(error, model: resolvedPostProcessingModel)
      host.attachFailureDiagnostics(to: session)
      let offersRetry = host.offerPostProcessingRetry(for: session)
      self.hud.finishFailure(headline: "Post-processing failed", message: friendly, showRetryHint: offersRetry)
      return PostProcessingStep(text: input, failureMessage: friendly)
    }
  }
}
