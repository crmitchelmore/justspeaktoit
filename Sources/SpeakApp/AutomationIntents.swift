import AppIntents
import Foundation
import SpeakCore

// App Intents (Shortcuts) surface for the mac app. The intents are thin: they
// resolve the shared AppEnvironment and delegate to the same managers the
// hotkey/UI paths use; parameter mapping and validation live in
// `SpeakCore/AutomationIntentSupport.swift` where they are unit-tested.

// MARK: - Errors

enum AutomationIntentError: LocalizedError {
  case appNotReady
  case alreadyRecording
  case noActiveRecording
  case noTranscriptionYet
  case emptyTranscript
  case openRouterKeyMissing
  case noPolishOutput
  case sessionFailed(String)

  var errorDescription: String? {
    switch self {
    case .appNotReady:
      return "Just Speak to It is still starting up. Open the app and try again."
    case .alreadyRecording:
      return "A dictation session is already in progress."
    case .noActiveRecording:
      return "No dictation session is running."
    case .noTranscriptionYet:
      return "No transcriptions in history yet."
    case .emptyTranscript:
      return "The recording produced no text."
    case .openRouterKeyMissing:
      return "Polish Text needs an OpenRouter API key. Add one in Settings → API Keys."
    case .noPolishOutput:
      return "The model returned no text."
    case .sessionFailed(let message):
      return message
    }
  }
}

/// Resolves the shared app environment for an intent. The environment
/// bootstraps when the SwiftUI scene appears, which can lag the first intent
/// when Shortcuts launches the app — poll briefly before giving up.
@MainActor
private func automationEnvironment() async throws -> AppEnvironment {
  for _ in 0..<50 {
    if let environment = AppEnvironment.shared {
      return environment
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
  }
  guard let environment = AppEnvironment.shared else {
    throw AutomationIntentError.appNotReady
  }
  return environment
}

// MARK: - Start Dictation

struct StartDictationIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Dictation"
  static var description = IntentDescription(
    "Starts a dictation session, exactly like pressing the hotkey. Pair with Stop Dictation to finish."
  )
  static var openAppWhenRun: Bool = false

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let environment = try await automationEnvironment()
    guard !environment.main.isDictationSessionActive else {
      throw AutomationIntentError.alreadyRecording
    }
    let started = await environment.main.startDictationFromAutomation()
    if case .failed(let message) = environment.main.state {
      throw AutomationIntentError.sessionFailed(message)
    }
    guard started else {
      let reason = environment.main.missingLiveAPIKeyAlert?.message ?? "Dictation could not start."
      throw AutomationIntentError.sessionFailed(reason)
    }
    return .result(dialog: "Dictation started. Run \"Stop Dictation\" to finish.")
  }
}

// MARK: - Stop Dictation

struct StopDictationIntent: AppIntent {
  static var title: LocalizedStringResource = "Stop Dictation"
  static var description = IntentDescription(
    "Stops the active dictation session, delivers the text as configured, and returns the transcript."
  )
  static var openAppWhenRun: Bool = false

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let environment = try await automationEnvironment()
    guard environment.main.isDictationSessionActive else {
      throw AutomationIntentError.noActiveRecording
    }
    guard let item = await environment.main.stopDictationFromAutomation() else {
      if case .failed(let message) = environment.main.state {
        throw AutomationIntentError.sessionFailed(message)
      }
      throw AutomationIntentError.emptyTranscript
    }
    guard let text = AutomationIntentSupport.bestTranscript(
      raw: item.rawTranscription,
      polished: item.postProcessedTranscription
    ) else {
      throw AutomationIntentError.emptyTranscript
    }
    return .result(value: text)
  }
}

// MARK: - Transcribe Audio File

struct TranscribeAudioFileIntent: AppIntent {
  static var title: LocalizedStringResource = "Transcribe Audio File"
  static var description = IntentDescription(
    "Transcribes an audio file with your configured transcription provider and returns the text."
  )
  static var openAppWhenRun: Bool = false

  // No supportedContentTypes: that Parameter initializer needs macOS 15 and
  // the app targets macOS 14. The extension check below validates instead.
  @Parameter(title: "Audio File")
  var file: IntentFile

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let environment = try await automationEnvironment()
    let fileExtension = try AutomationIntentSupport.validatedAudioExtension(
      forFilename: file.filename
    )
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(fileExtension)
    try file.data.write(to: temporaryURL)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    let result = try await environment.transcription.transcribeFile(at: temporaryURL)
    await Self.recordInHistory(result, in: environment)
    return .result(value: result.text)
  }

  /// Files transcribed through Shortcuts land in history like any other
  /// transcription, matching the iOS intent and the in-app file import. The
  /// temporary copy is deleted when the intent returns, so no audio URL is
  /// stored; blank results are skipped rather than creating an empty entry.
  @MainActor
  private static func recordInHistory(
    _ result: TranscriptionResult,
    in environment: AppEnvironment
  ) async {
    guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let now = Date()
    await environment.history.append(
      HistoryItem(
        modelsUsed: [result.modelIdentifier],
        modelUsages: [
          ModelUsage(modelIdentifier: result.modelIdentifier, phase: .transcriptionBatch)
        ],
        rawTranscription: result.text,
        postProcessedTranscription: nil,
        recordingDuration: result.duration,
        cost: result.cost.map {
          HistoryCost(total: $0.totalCost, currency: $0.currency, breakdown: $0)
        },
        audioFileURL: nil,
        networkExchanges: [],
        events: [
          HistoryEvent(
            kind: .transcriptionReceived,
            description: "Transcribed \(result.modelIdentifier) via Shortcuts"
          )
        ],
        phaseTimestamps: PhaseTimestamps(
          recordingStarted: nil,
          recordingEnded: nil,
          transcriptionStarted: nil,
          transcriptionEnded: now,
          postProcessingStarted: nil,
          postProcessingEnded: nil,
          outputDelivered: nil
        ),
        trigger: HistoryTrigger(
          gesture: .uiButton,
          hotKeyDescription: "Shortcuts",
          outputMethod: .none,
          destinationApplication: nil
        ),
        personalCorrections: nil,
        errors: [],
        source: .importedFile
      )
    )
  }
}

// MARK: - Get Last Transcription

struct GetLastTranscriptionIntent: AppIntent {
  static var title: LocalizedStringResource = "Get Last Transcription"
  static var description = IntentDescription(
    "Returns the most recent transcription from history, preferring the polished text."
  )
  static var openAppWhenRun: Bool = false

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let environment = try await automationEnvironment()
    if environment.history.items.isEmpty {
      await environment.history.loadFromDisk()
    }
    let text = environment.history.items.lazy
      .compactMap { item in
        AutomationIntentSupport.bestTranscript(
          raw: item.rawTranscription,
          polished: item.postProcessedTranscription
        )
      }
      .first
    guard let text else {
      throw AutomationIntentError.noTranscriptionYet
    }
    return .result(value: text)
  }
}

// MARK: - Polish Text

struct PolishTextIntent: AppIntent {
  static var title: LocalizedStringResource = "Polish Text"
  static var description = IntentDescription(
    "Cleans up text with your post-processing model. A custom prompt overrides the cleanup instructions."
  )
  static var openAppWhenRun: Bool = false

  @Parameter(title: "Text")
  var text: String

  @Parameter(title: "Custom Prompt")
  var customPrompt: String?

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let environment = try await automationEnvironment()
    // Asks the post-processing manager, not OpenRouter: a local or Apple
    // Foundation model needs no key at all.
    guard await environment.postProcessing.hasRequiredAPIKey() else {
      throw AutomationIntentError.openRouterKeyMissing
    }
    let request = AutomationIntentSupport.polishRequest(
      text: text,
      customPrompt: customPrompt,
      defaultSystemPrompt: environment.postProcessing.effectiveSystemPrompt()
    )
    let polished = try await environment.postProcessing.polish(
      text: text,
      systemPrompt: request.systemPrompt,
      userMessage: request.userMessage
    )
    guard !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AutomationIntentError.noPolishOutput
    }
    return .result(value: polished)
  }
}

// MARK: - App Shortcuts

struct SpeakAutomationShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartDictationIntent(),
      phrases: [
        "Start dictation with \(.applicationName)",
        "Start recording with \(.applicationName)"
      ],
      shortTitle: "Start Dictation",
      systemImageName: "mic.badge.plus"
    )

    AppShortcut(
      intent: StopDictationIntent(),
      phrases: [
        "Stop dictation with \(.applicationName)",
        "Stop recording with \(.applicationName)"
      ],
      shortTitle: "Stop Dictation",
      systemImageName: "stop.fill"
    )

    AppShortcut(
      intent: GetLastTranscriptionIntent(),
      phrases: [
        "Get my last transcription from \(.applicationName)",
        "Get the last dictation from \(.applicationName)"
      ],
      shortTitle: "Last Transcription",
      systemImageName: "clock.arrow.circlepath"
    )
  }
}
