#if os(iOS)
import AppIntents
import Foundation
import SpeakCore

// Shortcuts automation surface for iOS, extending the recording intents in
// `TranscriptionIntents.swift`. The intents are thin: parameter mapping and
// validation live in `SpeakCore/AutomationIntentSupport.swift` where they are
// unit-tested, and all real work happens in the existing services. They are
// internal on purpose — nothing outside SpeakiOSLib references them, and the
// AppIntents metadata extractor does not need public visibility.

// MARK: - Errors

enum AutomationIntentError: LocalizedError {
    case noActiveRecording
    case emptyTranscript
    case noTranscriptionYet
    case unsupportedBatchModel(String)
    case openRouterKeyMissing
    case noPolishOutput

    var errorDescription: String? {
        switch self {
        case .noActiveRecording:
            return "No recording is in progress."
        case .emptyTranscript:
            return "The recording produced no text, or another stop was already in progress."
        case .noTranscriptionYet:
            return "No transcriptions in history yet."
        case .unsupportedBatchModel(let model):
            return "The configured batch model (\(model)) isn't supported for file transcription "
                + "on iPhone. Choose a supported model in Settings."
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
struct StopDictationIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "Stop Dictation and Get Text"
    static var description = IntentDescription(
        "Stops the current recording and returns the final transcript for use in later Shortcut actions."
    )

    static var openAppWhenRun: Bool = false
    /// Returns private transcript data, so never run on a locked device.
    /// (The plain Stop Recording intent, which returns no transcript, stays
    /// available for locked Action Button flows.)
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let service = await TranscriptionRecordingService.shared
        guard await service.isRunning else {
            throw AutomationIntentError.noActiveRecording
        }
        let destination = await AppSettings.shared.hardwareTriggerDestination
        let result = await service.stopRecording(destination: destination)
        // A duplicate stop (second Shortcut, Action Button race) intentionally
        // yields an empty no-op result, and a silent or failed recording can
        // finish empty too. Neither is a transcript, so fail the Shortcut
        // instead of handing "" to downstream actions as success.
        guard let text = AutomationIntentSupport.bestTranscript(raw: result.text, polished: nil) else {
            throw AutomationIntentError.emptyTranscript
        }
        return .result(value: text)
    }
}

// MARK: - Transcribe Audio File

struct TranscribeAudioFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Transcribe Audio File"
    static var description = IntentDescription(
        "Transcribes an audio file with your configured batch model and returns the text."
    )

    static var openAppWhenRun: Bool = false
    /// Sends user audio to the configured provider and returns its transcript,
    /// so never run on a locked device.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    // No supportedContentTypes: that Parameter initializer needs iOS 18 and
    // the app targets iOS 17. The extension check below validates instead.
    @Parameter(title: "Audio File")
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let fileExtension = try AutomationIntentSupport.validatedAudioExtension(
            forFilename: file.filename
        )
        let settings = AppSettings.shared
        await settings.ensureKeysLoaded()
        let model = settings.batchTranscriptionModel
        // Only models with an iOS upload client may run. A retained direct-
        // provider identifier (for example a Soniox model configured on Mac)
        // would otherwise fall through to OpenRouter with the wrong credential.
        guard AppSettings.supportedBatchModels.contains(where: { $0.id == model }) else {
            throw AutomationIntentError.unsupportedBatchModel(model)
        }
        let temporaryURL = try await Self.stageAudioForTranscription(
            file: file,
            fileExtension: fileExtension
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

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

    /// Stages the intent's audio in a uniquely named temporary file, enforcing
    /// the automation size cap first. Non-isolated async, so the copy runs off
    /// the main actor and a large payload never stalls the UI; the file-backed
    /// representation is preferred over materializing `IntentFile.data` in
    /// memory when available.
    private static func stageAudioForTranscription(
        file: IntentFile,
        fileExtension: String
    ) async throws -> URL {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        if let sourceURL = file.fileURL {
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            if let byteCount = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                try AutomationIntentSupport.validateAudioFileSize(byteCount)
            }
            try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
        } else {
            let data = file.data
            try AutomationIntentSupport.validateAudioFileSize(data.count)
            try data.write(to: temporaryURL)
        }
        return temporaryURL
    }
}

// MARK: - Get Last Transcription

struct GetLastTranscriptionIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Last Transcription"
    static var description = IntentDescription(
        "Returns the most recent transcription from history, preferring the polished text."
    )

    static var openAppWhenRun: Bool = false
    /// Returns private transcript data, so never run on a locked device.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
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

struct PolishTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Polish Text"
    static var description = IntentDescription(
        "Cleans up text with your post-processing model. A custom prompt overrides the cleanup instructions."
    )

    static var openAppWhenRun: Bool = false
    /// Can send user-provided text to the configured remote provider, so never
    /// run on a locked device.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Custom Prompt")
    var customPrompt: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let settings = AppSettings.shared
        await settings.ensureKeysLoaded()
        let model = settings.postProcessingModel
        guard model == AppleLocalModels.foundationModelID || settings.hasOpenRouterKey else {
            throw AutomationIntentError.openRouterKeyMissing
        }
        let request = AutomationIntentSupport.polishRequest(
            text: text,
            customPrompt: customPrompt,
            defaultSystemPrompt: iOSPostProcessingManager.effectiveSystemPrompt()
        )
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
