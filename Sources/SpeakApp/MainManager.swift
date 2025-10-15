import AVFoundation
import AppKit
import Combine
import Foundation

@MainActor
final class MainManager: ObservableObject {
  enum State: Equatable {
    case idle
    case recording
    case processing
    case delivering
    case completed(HistoryItem)
    case failed(String)
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var livePreview: String = ""
  @Published private(set) var lastErrorMessage: String?

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let hotKeyManager: HotKeyManager
  private let audioFileManager: AudioFileManager
  private let transcriptionManager: TranscriptionManager
  private let postProcessingManager: PostProcessingManager
  private let historyManager: HistoryManager
  private let hudManager: HUDManager
  private let personalLexicon: PersonalLexiconService

  private var activeSession: ActiveSession?
  private var cancellables: Set<AnyCancellable> = []
  private var hotKeyTokens: [HotKeyListenerToken] = []
  private var lastDoubleTapEventUptime: TimeInterval = 0

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    hotKeyManager: HotKeyManager,
    audioFileManager: AudioFileManager,
    transcriptionManager: TranscriptionManager,
    postProcessingManager: PostProcessingManager,
    historyManager: HistoryManager,
    hudManager: HUDManager,
    personalLexicon: PersonalLexiconService
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.hotKeyManager = hotKeyManager
    self.audioFileManager = audioFileManager
    self.transcriptionManager = transcriptionManager
    self.postProcessingManager = postProcessingManager
    self.historyManager = historyManager
    self.hudManager = hudManager
    self.personalLexicon = personalLexicon

    transcriptionManager.$livePartialText
      .receive(on: RunLoop.main)
      .sink { [weak self] text in
        self?.livePreview = text
      }
      .store(in: &cancellables)

    configureHotKeys()
  }

  var isBusy: Bool {
    switch state {
    case .idle, .completed, .failed:
      return false
    case .recording, .processing, .delivering:
      return true
    }
  }

  func toggleRecordingFromUI() {
    if activeSession == nil {
      Task { await startSession(trigger: .uiButton) }
    } else {
      Task { await endSession(trigger: .uiButton) }
    }
  }

  func userRequestedStopDueToError() {
    guard let session = activeSession else { return }
    session.errors.append(
      HistoryError(phase: .recording, message: "User cancelled", debugDescription: nil)
    )
    cleanupAfterFailure(message: "Recording cancelled", preserveFile: false)
  }

  private func configureHotKeys() {
    hotKeyTokens.append(
      hotKeyManager.register(gesture: .holdStart) { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          guard self.appSettings.hotKeyActivationStyle.allowsHold else { return }
          await self.startSession(trigger: .hold)
        }
      }
    )

    hotKeyTokens.append(
      hotKeyManager.register(gesture: .holdEnd) { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          guard self.appSettings.hotKeyActivationStyle.allowsHold else { return }
          await self.endSession(trigger: .hold)
        }
      }
    )

    hotKeyTokens.append(
      hotKeyManager.register(gesture: .doubleTap) { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          guard self.appSettings.hotKeyActivationStyle.allowsDoubleTap else { return }
          let now = ProcessInfo.processInfo.systemUptime
          if now - self.lastDoubleTapEventUptime < 0.25 {
            return
          }
          self.lastDoubleTapEventUptime = now

          if let session = self.activeSession {
            guard session.gesture == .doubleTap else { return }
            await self.endSession(trigger: .doubleTap)
          } else {
            await self.startSession(trigger: .doubleTap)
          }
        }
      }
    )

    hotKeyTokens.append(
      hotKeyManager.register(gesture: .singleTap) { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          guard self.appSettings.hotKeyActivationStyle.allowsDoubleTap else { return }
          if let session = self.activeSession, session.gesture == .doubleTap {
            await self.endSession(trigger: .singleTap)
          }
        }
      }
    )

    hotKeyManager.startMonitoring()
  }

  private func startSession(trigger: SessionTriggerSource) async {
    guard activeSession == nil else { return }

    let gesture = trigger.historyGesture
    let session = ActiveSession(gesture: gesture, hotKeyDescription: "Fn")
    activeSession = session
    state = .recording
    lastErrorMessage = nil
    session.events.append(
      HistoryEvent(
        kind: .recordingStarted,
        description: "Recording started via \(gesture.rawValue)"
      )
    )

    if appSettings.showHUDDuringSessions {
      hudManager.beginRecording()
    }

    do {
      _ = try await audioFileManager.startRecording()
      if appSettings.transcriptionMode == .liveNative {
        try await transcriptionManager.startLiveTranscription()
      }
    } catch {
      session.errors.append(
        HistoryError(
          phase: .recording,
          message: "Failed to start recording",
          debugDescription: error.localizedDescription
        )
      )
      cleanupAfterFailure(message: error.localizedDescription, preserveFile: false)
    }
  }

  private func endSession(trigger: SessionTriggerSource) async {
    guard let session = activeSession else { return }

    let tailDuration = max(appSettings.postRecordingTailDuration, 0)
    if tailDuration > 0 {
      do {
        try await Task.sleep(nanoseconds: UInt64(tailDuration * 1_000_000_000))
      } catch {
        // Ignored: sleep cancellation simply means we stop immediately.
      }
    }

    state = .processing
    session.recordingEnded = Date()
    let stopDescription: String
    if tailDuration > 0 {
      let tailText = String(format: "%.1f", tailDuration)
      stopDescription =
        "Recording stopped via \(trigger.historyGesture.rawValue) (tail +\(tailText)s)"
    } else {
      stopDescription = "Recording stopped via \(trigger.historyGesture.rawValue)"
    }
    session.events.append(
      HistoryEvent(
        kind: .recordingStopped,
        timestamp: Date(),
        description: stopDescription
      )
    )

    do {
      let summary = try await audioFileManager.stopRecording()
      session.recordingSummary = summary
      session.recordingEnded = summary.startedAt.addingTimeInterval(summary.duration)

      if appSettings.transcriptionMode == .liveNative {
        session.transcriptionStarted = Date()
        hudManager.beginTranscribing()
        let result = try await transcriptionManager.stopLiveTranscription()
        session.transcriptionEnded = Date()
        session.transcriptionResult = result
        session.modelsUsed.insert(result.modelIdentifier)
        session.modelUsages.append(ModelUsage(modelIdentifier: result.modelIdentifier, phase: .transcriptionLive))
        session.events.append(
          HistoryEvent(kind: .transcriptionReceived, description: "Live transcription complete")
        )
      } else {
        hudManager.beginTranscribing()
        session.transcriptionStarted = Date()
        guard
          await ensureBatchAPIKeyAvailable(
            for: session,
            message:
              "Batch transcription requires an OpenRouter API key. Add one in Settings › API Keys."
          )
        else {
          return
        }
        let result = try await transcriptionManager.transcribeFile(at: summary.url)
        session.transcriptionEnded = Date()
        session.transcriptionResult = result
        session.modelsUsed.insert(result.modelIdentifier)
        session.modelUsages.append(ModelUsage(modelIdentifier: result.modelIdentifier, phase: .transcriptionBatch))
        session.events.append(
          HistoryEvent(kind: .transcriptionReceived, description: "Batch transcription complete")
        )
        if let payload = result.rawPayload {
          session.networkExchanges.append(
            HistoryNetworkExchange(
              url: URL(string: "https://openrouter.ai/api/v1/responses")!,
              method: "POST",
              requestHeaders: [
                "Model": result.modelIdentifier,
                "Content-Type": "application/json",
              ],
              requestBodyPreview: "JSON payload with \(summary.url.lastPathComponent) audio",
              responseCode: 200,
              responseHeaders: [:],
              responseBodyPreview: String(payload.prefix(800))
            )
          )
        }
        if let cost = result.cost {
          session.recordCostFragment(cost)
        }
      }

      let baseText = session.transcriptionResult?.text ?? ""
      let lexiconContext = makeLexiconContext(for: baseText, destination: nil)
      let corrections = personalLexicon.apply(to: baseText, context: lexiconContext)
      session.personalCorrections = PersonalLexiconHistorySummary(
        applied: corrections.applied,
        suggestions: corrections.suggestions,
        contextTags: Array(lexiconContext.tags).sorted(),
        destinationApplication: lexiconContext.destinationApplication
      )
      session.lexiconContext = lexiconContext
      var finalText = corrections.transformedText
      var postProcessingFailureNotice: (headline: String, message: String)?

      if appSettings.postProcessingEnabled {
        hudManager.beginPostProcessing()
        session.postProcessingStarted = Date()
        guard
          await ensurePostProcessingAPIKeyAvailable(
            for: session,
            message:
              "Post-processing requires an OpenRouter API key. Add one in Settings › API Keys."
          )
        else {
          return
        }
        let configuredModel = appSettings.postProcessingModel
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPostProcessingModel =
          configuredModel.isEmpty
          ? "inception/mercury"
          : configuredModel
        let postProcessingInput = finalText
        let outcomeResult = await postProcessingManager.process(
          rawText: postProcessingInput,
          context: session.lexiconContext,
          corrections: session.personalCorrections
        )
        switch outcomeResult {
        case .success(let outcome):
          session.postProcessingEnded = Date()
          session.postProcessingOutcome = outcome
          finalText = outcome.processed
          if let response = outcome.response {
            session.events.append(
              HistoryEvent(kind: .postProcessingReceived, description: "Post-processing complete")
            )
            if let payload = response.rawPayload {
              session.networkExchanges.append(
                HistoryNetworkExchange(
                  url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                  method: "POST",
                  requestHeaders: ["Model": resolvedPostProcessingModel],
                  requestBodyPreview: postProcessingRequestPreview(
                    systemPrompt: outcome.systemPrompt,
                    rawText: postProcessingInput
                  ),
                  responseCode: 200,
                  responseHeaders: [:],
                  responseBodyPreview: String(payload.prefix(800))
                )
              )
            }
            session.modelsUsed.insert(resolvedPostProcessingModel)
            session.modelUsages.append(ModelUsage(modelIdentifier: resolvedPostProcessingModel, phase: .postProcessing))
            if let cost = response.cost {
              session.recordCostFragment(cost)
            }
          }
        case .failure(let error):
          session.postProcessingEnded = Date()
          let friendly = Self.friendlyPostProcessingMessage(
            for: error,
            modelIdentifier: resolvedPostProcessingModel
          )
          session.errors.append(
            HistoryError(
              phase: .postProcessing,
              message: friendly,
              debugDescription: error.localizedDescription
            )
          )
          session.events.append(HistoryEvent(kind: .error, description: friendly))
          postProcessingFailureNotice = (headline: "Post-processing failed", message: friendly)
          hudManager.finishFailure(headline: "Post-processing failed", message: friendly)
        }
      }

      state = .delivering
      if postProcessingFailureNotice == nil {
        hudManager.beginDelivering()
      }
      let output = SmartTextOutput(permissionsManager: permissionsManager, appSettings: appSettings)
      let outputResult = output.output(text: finalText)
      session.outputMethod = outputResult.method
      session.outputDelivered = Date()

      if let error = outputResult.error {
        session.errors.append(
          HistoryError(
            phase: .output,
            message: "Failed to deliver text",
            debugDescription: error.localizedDescription
          )
        )
        hudManager.finishFailure(headline: "Delivery failed", message: error.localizedDescription)
        state = .failed(error.localizedDescription)
        lastErrorMessage = error.localizedDescription
      } else {
        session.events.append(
          HistoryEvent(kind: .outputDelivered, description: "Output delivered successfully")
        )
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
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
        if let notice = postProcessingFailureNotice {
          lastErrorMessage = notice.message
          state = .failed(notice.message)
        } else {
          hudManager.finishSuccess(message: "Delivered")
          state = .completed(historyItem)
        }
      }

      activeSession = nil
    } catch {
      session.errors.append(
        HistoryError(
          phase: .transcription,
          message: "Processing failed",
          debugDescription: error.localizedDescription
        )
      )
      cleanupAfterFailure(message: error.localizedDescription, preserveFile: true)
    }
  }

  func reprocessHistoryItem(_ item: HistoryItem) async {
    guard activeSession == nil else { return }
    guard let url = item.audioFileURL else { return }

    state = .processing
    hudManager.beginTranscribing()

    let session = ActiveSession(
      gesture: .uiButton, hotKeyDescription: item.trigger.hotKeyDescription)
    activeSession = session

    let summary = makeRecordingSummary(from: url, fallbackDuration: item.recordingDuration)
    session.recordingSummary = summary
    session.recordingStarted = summary.startedAt
    session.recordingEnded = summary.startedAt.addingTimeInterval(summary.duration)
    session.events.append(
      HistoryEvent(kind: .recordingStarted, description: "Reprocess requested")
    )

    do {
      session.transcriptionStarted = Date()
      session.events.append(
        HistoryEvent(kind: .transcriptionSubmitted, description: "Submitting to batch model")
      )
      let result = try await transcriptionManager.transcribeFile(at: url)
      session.transcriptionEnded = Date()
      session.transcriptionResult = result
      session.modelsUsed.insert(result.modelIdentifier)
      session.modelUsages.append(ModelUsage(modelIdentifier: result.modelIdentifier, phase: .transcriptionBatch))
      session.events.append(
        HistoryEvent(kind: .transcriptionReceived, description: "Batch transcription complete")
      )

      if let payload = result.rawPayload {
        session.networkExchanges.append(
          HistoryNetworkExchange(
            url: URL(string: "https://openrouter.ai/api/v1/responses")!,
            method: "POST",
            requestHeaders: [
              "Model": result.modelIdentifier,
              "Content-Type": "application/json",
            ],
            requestBodyPreview: "JSON payload with \(url.lastPathComponent) audio",
            responseCode: 200,
            responseHeaders: [:],
            responseBodyPreview: String(payload.prefix(800))
          )
        )
      }
      if let cost = result.cost {
        session.recordCostFragment(cost)
      }

      let baseText = result.text
      let lexiconContext = makeLexiconContext(for: baseText, destination: nil)
      let corrections = personalLexicon.apply(to: baseText, context: lexiconContext)
      session.personalCorrections = PersonalLexiconHistorySummary(
        applied: corrections.applied,
        suggestions: corrections.suggestions,
        contextTags: Array(lexiconContext.tags).sorted(),
        destinationApplication: lexiconContext.destinationApplication
      )
      session.lexiconContext = lexiconContext
      var finalText = corrections.transformedText

      if appSettings.postProcessingEnabled {
        hudManager.beginPostProcessing()
        session.postProcessingStarted = Date()
        guard
          await ensurePostProcessingAPIKeyAvailable(
            for: session,
            message:
              "Post-processing requires an OpenRouter API key. Add one in Settings › API Keys."
          )
        else {
          return
        }
        session.events.append(
          HistoryEvent(kind: .postProcessingSubmitted, description: "Sending to post-processor")
        )
        let postProcessingInput = finalText
        let outcomeResult = await postProcessingManager.process(
          rawText: postProcessingInput,
          context: session.lexiconContext,
          corrections: session.personalCorrections
        )
        switch outcomeResult {
        case .success(let outcome):
          session.postProcessingEnded = Date()
          session.postProcessingOutcome = outcome
          finalText = outcome.processed
          if let response = outcome.response {
            session.events.append(
              HistoryEvent(kind: .postProcessingReceived, description: "Post-processing complete")
            )
            if let payload = response.rawPayload {
              session.networkExchanges.append(
                HistoryNetworkExchange(
                  url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                  method: "POST",
                  requestHeaders: ["Model": appSettings.postProcessingModel],
                  requestBodyPreview: postProcessingRequestPreview(
                    systemPrompt: outcome.systemPrompt,
                    rawText: postProcessingInput
                  ),
                  responseCode: 200,
                  responseHeaders: [:],
                  responseBodyPreview: String(payload.prefix(800))
                )
              )
            }
            if let cost = response.cost {
              session.recordCostFragment(cost)
            }
            if !appSettings.postProcessingModel.isEmpty {
              session.modelsUsed.insert(appSettings.postProcessingModel)
              session.modelUsages.append(ModelUsage(modelIdentifier: appSettings.postProcessingModel, phase: .postProcessing))
            }
          }
        case .failure(let error):
          let friendly = Self.friendlyPostProcessingMessage(
            for: error,
            modelIdentifier: appSettings.postProcessingModel
          )
          session.errors.append(
            HistoryError(
              phase: .postProcessing,
              message: friendly,
              debugDescription: error.localizedDescription
            )
          )
          session.events.append(HistoryEvent(kind: .error, description: friendly))
        }
      }

      hudManager.beginDelivering()
      hudManager.finishSuccess(message: "Reprocessed")
      session.events.append(
        HistoryEvent(kind: .outputDelivered, description: "Reprocess stored in history")
      )
      session.outputMethod = .none
      let historyItem = session.buildHistoryItem(finalText: finalText)
      state = .completed(historyItem)
      await historyManager.append(historyItem)

      activeSession = nil
    } catch {
      session.errors.append(
        HistoryError(
          phase: .transcription,
          message: "Reprocess failed",
          debugDescription: error.localizedDescription
        )
      )
      hudManager.finishFailure(message: error.localizedDescription)
      state = .failed(error.localizedDescription)
      let historyItem = session.buildHistoryItem(finalText: session.transcriptionResult?.text)
      await historyManager.append(historyItem)
      activeSession = nil
    }
  }

  private func ensureBatchAPIKeyAvailable(for session: ActiveSession, message: String) async
    -> Bool
  {
    guard await transcriptionManager.hasValidBatchAPIKey() else {
      await handleMissingAPIKey(
        session,
        phase: .transcription,
        message: message
      )
      return false
    }
    return true
  }

  private func ensurePostProcessingAPIKeyAvailable(for session: ActiveSession, message: String)
    async -> Bool
  {
    guard await postProcessingManager.hasRequiredAPIKey() else {
      await handleMissingAPIKey(session, phase: .postProcessing, message: message)
      return false
    }
    return true
  }

  private func handleMissingAPIKey(
    _ session: ActiveSession,
    phase: HistoryError.Phase,
    message: String
  ) async {
    session.errors.append(HistoryError(phase: phase, message: message, debugDescription: nil))
    session.events.append(HistoryEvent(kind: .error, description: message))
    hudManager.finishFailure(message: message)
    state = .failed(message)
    lastErrorMessage = message
    let historyItem = session.buildHistoryItem(finalText: session.transcriptionResult?.text)
    await historyManager.append(historyItem)
    activeSession = nil
  }

  private func postProcessingRequestPreview(systemPrompt: String, rawText: String) -> String {
    let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let promptSection = trimmedPrompt.isEmpty ? "<default prompt>" : trimmedPrompt
    let truncatedRaw = rawText.prefix(600)
    return "System Prompt:\n\(promptSection)\n\nUser Text:\n\(truncatedRaw)"
  }

  private static func friendlyPostProcessingMessage(
    for error: Error,
    modelIdentifier: String
  ) -> String {
    let trimmedModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = ModelCatalog.friendlyName(for: trimmedModel.isEmpty ? "inception/mercury" : trimmedModel)

    if let routerError = error as? OpenRouterClientError {
      switch routerError {
      case .apiKeyMissing:
        return "Post-processing skipped because no OpenRouter API key is configured. Add one in Settings › API Keys."
      case .invalidResponse:
        return "OpenRouter returned an unexpected response while using \(displayName)."
      case .httpStatus(let code, let body):
        if let detail = parseOpenRouterMessage(from: body) {
          return "OpenRouter rejected \(displayName) (status \(code)): \(detail)"
        }
        return "OpenRouter responded with status \(code) while using \(displayName)."
      }
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
      return "Network error while contacting OpenRouter: \(nsError.localizedDescription)."
    }

    return error.localizedDescription
  }

  private static func parseOpenRouterMessage(from body: String) -> String? {
    guard let data = body.data(using: .utf8) else { return nil }
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if let errorDict = json["error"] as? [String: Any], let message = errorDict["message"] as? String {
        return message
      }
      if let message = json["message"] as? String {
        return message
      }
    }

    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.count > 200 {
      return String(trimmed.prefix(200)) + "…"
    }
    return trimmed
  }

  private func makeLexiconContext(for text: String, destination: String?) -> PersonalLexiconContext {
    var tags: Set<String> = []
    let lowered = text.lowercased()
    if lowered.contains("dear ") || lowered.contains("regards") || lowered.contains("sincerely") {
      tags.insert("formal")
    }
    if lowered.contains("meeting") || lowered.contains("agenda") || lowered.contains("project") || lowered.contains("quarterly") {
      tags.insert("work")
    }
    if lowered.contains("love") || lowered.contains("babe") || lowered.contains("sweetheart") {
      tags.insert("intimate")
    }
    if let destination, !destination.isEmpty {
      let lowerDest = destination.lowercased()
      if lowerDest.contains("mail") || lowerDest.contains("outlook") {
        tags.insert("formal")
      }
      if lowerDest.contains("messages") || lowerDest.contains("imessage") {
        tags.insert("casual")
      }
      if lowerDest.contains("slack") || lowerDest.contains("teams") {
        tags.insert("work")
      }
    }
    let window = String(text.suffix(400))
    return PersonalLexiconContext(
      tags: tags,
      destinationApplication: destination,
      recentTranscriptWindow: window
    )
  }

  private func cleanupAfterFailure(message: String, preserveFile: Bool) {
    lastErrorMessage = message
    hudManager.finishFailure(message: message)
    state = .failed(message)
    Task {
      await audioFileManager.cancelRecording(deleteFile: !preserveFile)
      if let session = activeSession {
        let historyItem = session.buildHistoryItem(finalText: session.transcriptionResult?.text)
        await historyManager.append(historyItem)
      }
    }

    activeSession = nil
  }
}
extension MainManager {
  fileprivate func makeRecordingSummary(from url: URL, fallbackDuration: TimeInterval)
    -> RecordingSummary
  {
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

private enum SessionTriggerSource {
  case hold
  case doubleTap
  case singleTap
  case uiButton

  var historyGesture: HistoryTrigger.HotKeyGesture {
    switch self {
    case .hold:
      return .hold
    case .doubleTap:
      return .doubleTap
    case .singleTap:
      return .singleTap
    case .uiButton:
      return .uiButton
    }
  }
}

private final class ActiveSession {
  let id = UUID()
  let gesture: HistoryTrigger.HotKeyGesture
  let hotKeyDescription: String
  var recordingSummary: RecordingSummary?
  var transcriptionResult: TranscriptionResult?
  var postProcessingOutcome: PostProcessingOutcome?
  var events: [HistoryEvent] = []
  var errors: [HistoryError] = []
  var networkExchanges: [HistoryNetworkExchange] = []
  var modelsUsed: Set<String> = []  // Deprecated: kept for backwards compatibility
  var modelUsages: [ModelUsage] = []
  var totalCost: Decimal = 0
  var costBreakdown: ChatCostBreakdown?
  var recordingStarted: Date
  var recordingEnded: Date?
  var transcriptionStarted: Date?
  var transcriptionEnded: Date?
  var postProcessingStarted: Date?
  var postProcessingEnded: Date?
  var outputDelivered: Date?
  var outputMethod: HistoryTrigger.OutputMethod = .none
  var destination: String?
  var personalCorrections: PersonalLexiconHistorySummary?
  var lexiconContext: PersonalLexiconContext = .empty

  init(gesture: HistoryTrigger.HotKeyGesture, hotKeyDescription: String) {
    self.gesture = gesture
    self.hotKeyDescription = hotKeyDescription
    self.recordingStarted = Date()
  }

  func recordCostFragment(_ fragment: ChatCostBreakdown) {
    totalCost += fragment.totalCost
    costBreakdown = ChatCostBreakdown(
      inputTokens: (costBreakdown?.inputTokens ?? 0) + fragment.inputTokens,
      outputTokens: (costBreakdown?.outputTokens ?? 0) + fragment.outputTokens,
      totalCost: totalCost,
      currency: fragment.currency
    )
  }

  func buildHistoryItem(finalText: String?) -> HistoryItem {
    let models = Array(modelsUsed)
    let cost: HistoryCost?
    if totalCost > 0, let breakdown = costBreakdown {
      cost = HistoryCost(total: totalCost, currency: breakdown.currency, breakdown: breakdown)
    } else {
      cost = nil
    }

    let createdAt = recordingStarted
    let updatedAt = Date()
    let trigger = HistoryTrigger(
      gesture: gesture,
      hotKeyDescription: hotKeyDescription,
      outputMethod: outputMethod,
      destinationApplication: destination
    )
    let timestamps = PhaseTimestamps(
      recordingStarted: recordingStarted,
      recordingEnded: recordingEnded,
      transcriptionStarted: transcriptionStarted,
      transcriptionEnded: transcriptionEnded,
      postProcessingStarted: postProcessingStarted,
      postProcessingEnded: postProcessingEnded,
      outputDelivered: outputDelivered
    )
    return HistoryItem(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt,
      modelsUsed: models,
      modelUsages: modelUsages,
      rawTranscription: transcriptionResult?.text,
      postProcessedTranscription: postProcessingOutcome?.processed,
      recordingDuration: recordingSummary?.duration ?? 0,
      cost: cost,
      audioFileURL: recordingSummary?.url,
      networkExchanges: networkExchanges,
      events: events,
      phaseTimestamps: timestamps,
      trigger: trigger,
      personalCorrections: personalCorrections,
      errors: errors
    )
  }
}

// @Implement: This file is the main lifecycle management for a transcription session. It orchestrates all the dependencies and passes commands between them.
// It depends on hotkey manager to tell it when to start recording. Based on the config from app settings it should know when to start recording either on: "a press and hold until release" OR "double tap until the next single tap"
// It should also depend on audio file manager to process and store the recorded audio file. This should always happen when we record as a backup and in the background even and especially when we are using live transcription
// The normal behaviour will be to pass the live audio to the transcription manager for native osx live transcription but it could be a streaming api or other at that point.
// This file also depends on the Post Processing Manager. If app settings say post processing should happen, it hands off the raw transcription to the Post Processing Manager and receives it back when complete.
// When a complete recording, transcribing, post processing etc cycle is complete this file should write a HistoryItem to the history manager. This includes if there are errors in any part of the process. Every time recording is started should result in some kind of history item even if it's only partially complete, and capture error information in detail.
// This file should use the text output to perform the output once all of the steps have been finished.
// This file also takes the HUD Manager as a dependency and calls the lifecycle events on the HUD Manager for it to be updated.
// It should call out to the HUD view to present that to the user the hud manager should update it. And pass any error messages back to it if things fail.
// Finally, after a session has completed and either succeeded and output the text or failed and an error has displayed, this file is responsible for cleaning up any open resources or sessions and closing them down properly.
