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

    /// The transcript comes back either way; this only redirects the
    /// side-effects (clipboard, history, background polish).
    @Parameter(
        title: "Destination",
        description: "Where the transcript goes. Leave unset to use the destination from Settings."
    )
    var destination: CaptureDestinationAppEnum?

    /// Issue #1015: without this, a "Clipboard and Polish" run hands the
    /// Shortcut the raw transcript and then quietly replaces the clipboard
    /// with the polished one, so the chain and the clipboard disagree and the
    /// user cannot tell which they pasted.
    ///
    /// Defaults to `false`, which is exactly what every saved Shortcut did
    /// before this parameter existed: stop, return the raw text immediately.
    @Parameter(
        title: "Wait For Polish",
        description: """
            Wait for the polished version and return that instead of the raw transcript. \
            Only has an effect when your destination polishes; if the polish fails or takes \
            too long, the raw transcript is returned.
            """,
        default: false
    )
    var waitForPolish: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Stop dictation and get text") {
            \.$destination
            \.$waitForPolish
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // The budget is the whole operation's, not the polish wait's alone.
        // `stopRecording` awaits transcription finalisation, History and the
        // destination side effects first; starting a full 12-second wait after
        // a slow stop is how a Wait For Polish shortcut overran the system's
        // limit and returned nothing at all — not even the raw transcript.
        let startedAt = ContinuousClock.now
        let service = await TranscriptionRecordingService.shared
        guard await service.isActive else {
            throw AutomationIntentError.noActiveRecording
        }
        // Captured before the stop: the polish that follows belongs to this
        // capture, and the wait must not be satisfied by an earlier one's.
        let runID = await service.activeCaptureID
        let resolved = await service.resolvedStopDestination(explicit: destination?.destination)
        let result = await service.stopRecording(
            destination: resolved,
            keyboardDeliverySource: .hardwareTrigger
        )
        let polishBudget = AutomationIntentSupport.PolishWait.remaining(
            requested: AutomationIntentSupport.PolishWait.defaultSeconds,
            elapsed: MonotonicClock.elapsedSeconds(since: startedAt)
        )
        let polished = waitForPolish && polishBudget > 0
            ? await service.awaitPolishedTranscript(timeout: polishBudget, forRun: runID)
            : nil
        // A duplicate stop (second Shortcut, Action Button race) intentionally
        // yields an empty no-op result, and a silent or failed recording can
        // finish empty too. Neither is a transcript, so fail the Shortcut
        // instead of handing "" to downstream actions as success.
        guard let text = AutomationIntentSupport.transcriptAfterPolishWait(
            raw: result.text,
            polished: polished,
            didWait: waitForPolish
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

    /// Both optional and both defaulting to the Settings value, so a Shortcut
    /// saved before they existed transcribes exactly as it did. The vocabulary
    /// and the option providers are #1076's, not a second set.
    @Parameter(
        title: "Language",
        description: "Language of the recording, such as en_GB. Leave unset to use the language from Settings.",
        optionsProvider: CaptureLanguageOptionsProvider()
    )
    var language: String?

    @Parameter(
        title: "Model",
        description: "Transcription model for this file. Leave unset to use the model from Settings.",
        optionsProvider: CaptureModelOptionsProvider()
    )
    var model: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$file)") {
            \.$language
            \.$model
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // One judgement for a file however it arrives — picked in Shortcuts,
        // received from the Share Sheet, or handed over by the Share extension
        // (issue #1020) — so the same recording gets the same answer and the
        // same message everywhere.
        let acceptance = try Self.acceptance(for: file)
        let settings = AppSettings.shared
        await settings.ensureKeysLoaded()
        let overrides = try CaptureParameterResolution.resolve(language: language, model: model)
        let modelID = overrides.modelID ?? settings.batchTranscriptionModel
        // Only models with an iOS upload client may run. A retained direct-
        // provider identifier (for example a Soniox model configured on Mac)
        // would otherwise fall through to OpenRouter with the wrong credential.
        guard AppSettings.supportedBatchModels.contains(where: { $0.id == modelID }) else {
            throw AutomationIntentError.unsupportedBatchModel(modelID)
        }
        let temporaryURL = try await Self.stageAudioForTranscription(
            file: file,
            acceptance: acceptance
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let result = try await IOSBatchTranscriber.transcribeFile(
            at: temporaryURL,
            model: modelID,
            apiKey: settings.batchAPIKey,
            language: overrides.languageIdentifier ?? settings.preferredModelLanguage,
            keywords: MetaMuseVoiceTranscribe.keywords(from: settings.transcriptionKeywords)
        )
        iOSHistoryManager.shared.recordTranscription(
            text: result.text,
            model: modelID,
            duration: result.duration
        )
        return .result(value: result.text)
    }

    /// Judges the incoming file before a byte is staged. When Shortcuts hands
    /// over a URL the file system is asked (so an undownloaded iCloud item and
    /// an unreadable one report themselves rather than failing later as
    /// "empty"); when it hands over data only, the size is already known.
    private static func acceptance(for file: IntentFile) throws -> SharedAudioAcceptance {
        guard let sourceURL = file.fileURL else {
            return try SharedAudioImport.evaluate(
                SharedAudioCandidate(filename: file.filename, byteCount: file.data.count)
            )
        }
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        let inspected = SharedAudioImport.inspect(fileURL: sourceURL)
        // `IntentFile.filename` is what the user named the recording;
        // `sourceURL` is often a sandbox temp path with a generated name. Take
        // the name from the intent and everything else from the file system.
        return try SharedAudioImport.evaluate(
            SharedAudioCandidate(
                filename: file.filename,
                byteCount: inspected.byteCount,
                isDownloaded: inspected.isDownloaded,
                isReadable: inspected.isReadable
            )
        )
    }

    /// Stages the intent's audio in a uniquely named temporary file.
    ///
    /// Non-isolated async, so the copy runs off the main actor and a large
    /// payload never stalls the UI. The file-backed representation is
    /// preferred and copied in 64 KiB chunks, so peak memory is one chunk
    /// rather than the whole recording; `IntentFile.data` is only materialized
    /// when Shortcuts gave no URL at all.
    private static func stageAudioForTranscription(
        file: IntentFile,
        acceptance: SharedAudioAcceptance
    ) async throws -> URL {
        let fileExtension = acceptance.fileExtension
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        if let sourceURL = file.fileURL {
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            try SharedAudioImport.stage(
                from: sourceURL,
                to: temporaryURL,
                // The accepted size, re-applied while copying: a file that
                // grows after inspection must not be staged past the limit.
                expectedByteCount: acceptance.byteCount
            )
        } else {
            try file.data.write(to: temporaryURL)
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
