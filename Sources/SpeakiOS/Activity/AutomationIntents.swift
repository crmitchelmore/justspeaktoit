#if os(iOS)
import AppIntents
import Foundation
import SpeakCore

// Shortcuts automation surface for iOS, extending the recording intents in
// `TranscriptionIntents.swift`. The intents are thin: parameter mapping and
// validation live in `SpeakCore/AutomationIntentSupport.swift` where they are
// unit-tested, and all real work happens in the existing services.

// MARK: - Errors

enum AutomationIntentError: LocalizedError {
    case noActiveRecording
    case noTranscriptionYet
    case openRouterKeyMissing
    case noPolishOutput

    var errorDescription: String? {
        switch self {
        case .noActiveRecording:
            return "No recording is in progress."
        case .noTranscriptionYet:
            return "No transcriptions in history yet."
        case .openRouterKeyMissing:
            return "Polish Text needs an OpenRouter API key. Add one in Settings."
        case .noPolishOutput:
            return "The model returned no text."
        }
    }
}

// MARK: - Stop Dictation and Get Text

/// Stops the current recording like `StopTranscriptionRecordingIntent`, but
/// returns the final transcript as the intent's value so later Shortcut
/// actions can consume it directly (the destination side-effects — clipboard,
/// history, background polish — still apply).
@available(iOS 18, *)
public struct StopDictationIntent: AudioRecordingIntent {
    public static var title: LocalizedStringResource = "Stop Dictation and Get Text"
    public static var description = IntentDescription(
        "Stops the current recording and returns the final transcript for use in later Shortcut actions."
    )

    public static var openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let service = await TranscriptionRecordingService.shared
        guard await service.isRunning else {
            throw AutomationIntentError.noActiveRecording
        }
        let destination = await AppSettings.shared.hardwareTriggerDestination
        let result = await service.stopRecording(destination: destination)
        return .result(value: result.text)
    }
}

// MARK: - Transcribe Audio File

public struct TranscribeAudioFileIntent: AppIntent {
    public static var title: LocalizedStringResource = "Transcribe Audio File"
    public static var description = IntentDescription(
        "Transcribes an audio file with your configured batch model and returns the text."
    )

    public static var openAppWhenRun: Bool = false

    // No supportedContentTypes: that Parameter initializer needs iOS 18 and
    // the app targets iOS 17. The extension check below validates instead.
    @Parameter(title: "Audio File")
    public var file: IntentFile

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let fileExtension = try AutomationIntentSupport.validatedAudioExtension(
            forFilename: file.filename
        )
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try file.data.write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let settings = AppSettings.shared
        await settings.ensureKeysLoaded()
        let model = settings.batchTranscriptionModel
        let result = try await IOSBatchTranscriber.transcribeFile(
            at: temporaryURL,
            model: model,
            apiKey: settings.batchAPIKey,
            language: settings.preferredModelLanguage
        )
        iOSHistoryManager.shared.recordTranscription(
            text: result.text,
            model: model,
            duration: result.duration
        )
        return .result(value: result.text)
    }
}

// MARK: - Get Last Transcription

public struct GetLastTranscriptionIntent: AppIntent {
    public static var title: LocalizedStringResource = "Get Last Transcription"
    public static var description = IntentDescription(
        "Returns the most recent transcription from history, preferring the polished text."
    )

    public static var openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let history = iOSHistoryManager.shared
        history.ensureLoaded()
        let text = history.items.lazy
            .compactMap { item in
                AutomationIntentSupport.bestTranscript(
                    raw: item.transcription,
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

public struct PolishTextIntent: AppIntent {
    public static var title: LocalizedStringResource = "Polish Text"
    public static var description = IntentDescription(
        "Cleans up text with your post-processing model. A custom prompt overrides the cleanup instructions."
    )

    public static var openAppWhenRun: Bool = false

    @Parameter(title: "Text")
    public var text: String

    @Parameter(title: "Custom Prompt")
    public var customPrompt: String?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let settings = AppSettings.shared
        await settings.ensureKeysLoaded()
        let model = settings.postProcessingModel
        guard model == AppleLocalModels.foundationModelID || settings.hasOpenRouterKey else {
            throw AutomationIntentError.openRouterKeyMissing
        }
        let request = AutomationIntentSupport.polishRequest(text: text, customPrompt: customPrompt)
        let polished = try await iOSPostProcessingManager.shared.polish(
            text: text,
            systemPrompt: request.systemPrompt,
            userMessage: request.userMessage,
            model: model,
            apiKey: settings.openRouterAPIKey
        )
        guard !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationIntentError.noPolishOutput
        }
        return .result(value: polished)
    }
}
#endif
