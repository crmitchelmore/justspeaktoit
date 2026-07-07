#if os(iOS)
import Foundation
import UIKit
import SpeakCore

/// Headless recording coordinator for Action Button / Shortcuts / Siri.
/// Manages the full lifecycle: start recording → live transcription → stop → clipboard → Live Activity.
@MainActor
public final class TranscriptionRecordingService: ObservableObject {
    public static let shared = TranscriptionRecordingService()

    @Published public private(set) var isRunning = false
    @Published public private(set) var partialText = ""
    @Published public private(set) var wordCount = 0

    private let audioSessionManager = AudioSessionManager()
    private let activityManager = TranscriptionActivityManager.shared
    private let sharedState = SharedTranscriptionState.shared

    private var appleTranscriber: iOSLiveTranscriber?
    private var deepgramTranscriber: DeepgramLiveTranscriber?
    private var elevenLabsTranscriber: ElevenLabsLiveTranscriber?
    private var openAITranscriber: OpenAIRealtimeLiveTranscriber?
    private var sharedTranscriber: SharedClientLiveTranscriber?
    private var startTime: Date?
    private var currentModel: String = ""

    private init() {}

    private var elapsedSeconds: Int {
        guard let start = startTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    private var modelDisplayName: String {
        if currentModel.hasPrefix("deepgram") { return "Deepgram" }
        if currentModel.hasPrefix("elevenlabs") { return "ElevenLabs" }
        if currentModel.hasPrefix("openai") { return "OpenAI gpt-realtime-whisper" }
        return "Apple Speech"
    }

    // MARK: - Public API

    /// Starts a headless recording session with Live Activity.
    public func startRecording() async throws { // swiftlint:disable:this function_body_length
        guard !isRunning else { return }

        let settings = AppSettings.shared
        currentModel = settings.selectedModel
        partialText = ""
        wordCount = 0
        startTime = Date()
        sharedState.clear()
        sharedState.isRecording = true
        sharedState.recordingStartTime = startTime

        // Fallback to Apple Speech if Deepgram selected but no API key
        if currentModel.hasPrefix("deepgram") && !settings.hasDeepgramKey {
            currentModel = "apple/local/SFSpeechRecognizer"
        }

        // Fallback to Apple Speech if ElevenLabs selected but no API key
        if currentModel.hasPrefix("elevenlabs") && !settings.hasElevenLabsKey {
            currentModel = "apple/local/SFSpeechRecognizer"
        }

        // Fallback to Apple Speech if OpenAI selected but no API key
        if currentModel.hasPrefix("openai") && !settings.hasOpenAIKey {
            currentModel = "apple/local/SFSpeechRecognizer"
        }

        // Fallback to Apple Speech if Cartesia selected but no API key
        if currentModel.hasPrefix("cartesia") && !settings.hasCartesiaKey {
            currentModel = "apple/local/SFSpeechRecognizer"
        }

        // Fallback to Apple Speech if Soniox selected but no API key
        if currentModel.hasPrefix("soniox") && !settings.hasSonioxKey {
            currentModel = "apple/local/SFSpeechRecognizer"
        }

        // Fallback to Apple Speech if Modulate selected but no API key
        if currentModel.hasPrefix("modulate") && !settings.hasModulateKey {
            currentModel = "apple/local/SFSpeechRecognizer"
        }

        // Fallback to Apple Speech if AssemblyAI selected but no API key
        if currentModel.hasPrefix("assemblyai") && !settings.hasAssemblyAIKey {
            currentModel = "apple/local/SFSpeechRecognizer"
        }

        // Fallback to Apple Speech if Gladia selected but no API key
        if currentModel.hasPrefix("gladia") && !settings.hasGladiaKey {
            currentModel = "apple/local/SFSpeechRecognizer"
        }

        // Live Activity is mandatory for AudioRecordingIntent
        activityManager.startActivity(provider: modelDisplayName)

        do {
            if currentModel.hasPrefix("deepgram") {
                let transcriber = DeepgramLiveTranscriber(audioSessionManager: audioSessionManager)
                transcriber.configure(apiKey: settings.deepgramAPIKey)
                transcriber.model = LiveTranscriptionRouting.route(for: currentModel)?.apiModelName
                    ?? currentModel.replacingOccurrences(of: "deepgram/", with: "")

                transcriber.onPartialResult = { [weak self] text, _ in
                    Task { @MainActor in
                        self?.handlePartialResult(text: text)
                    }
                }
                transcriber.onError = { [weak self] error in
                    Task { @MainActor in
                        self?.handleError(error)
                    }
                }

                deepgramTranscriber = transcriber
                appleTranscriber = nil
                elevenLabsTranscriber = nil
                try await transcriber.start()
            } else if currentModel.hasPrefix("elevenlabs") {
                let transcriber = ElevenLabsLiveTranscriber(audioSessionManager: audioSessionManager)
                transcriber.configure(apiKey: settings.elevenLabsAPIKey)
                transcriber.modelID = LiveTranscriptionRouting.route(for: currentModel)?.apiModelName
                    ?? currentModel.replacingOccurrences(of: "elevenlabs/", with: "")

                transcriber.onPartialResult = { [weak self] text, _ in
                    Task { @MainActor in
                        self?.handlePartialResult(text: text)
                    }
                }
                transcriber.onError = { [weak self] error in
                    Task { @MainActor in
                        self?.handleError(error)
                    }
                }

                elevenLabsTranscriber = transcriber
                deepgramTranscriber = nil
                appleTranscriber = nil
                openAITranscriber = nil
                try await transcriber.start()
            } else if currentModel.hasPrefix("openai") {
                let transcriber = OpenAIRealtimeLiveTranscriber(audioSessionManager: audioSessionManager)
                transcriber.configure(apiKey: settings.openAIAPIKey)
                transcriber.modelID = LiveTranscriptionRouting.route(for: currentModel)?.apiModelName
                    ?? currentModel.replacingOccurrences(of: "openai/", with: "")

                transcriber.onPartialResult = { [weak self] text, _ in
                    Task { @MainActor in
                        self?.handlePartialResult(text: text)
                    }
                }
                transcriber.onError = { [weak self] error in
                    Task { @MainActor in
                        self?.handleError(error)
                    }
                }

                openAITranscriber = transcriber
                elevenLabsTranscriber = nil
                deepgramTranscriber = nil
                appleTranscriber = nil
                sharedTranscriber = nil
                try await transcriber.start()
            } else if let route = LiveTranscriptionRouting.route(for: currentModel),
                      route.provider.isSupportedOnIOS {
                // Generic shared-client path (Cartesia, and future ported providers).
                let transcriber = SharedClientLiveTranscriber(
                    route: route,
                    apiKey: settings.liveAPIKey(for: route),
                    audioSessionManager: audioSessionManager
                )
                transcriber.onPartialResult = { [weak self] text, _ in
                    Task { @MainActor in self?.handlePartialResult(text: text) }
                }
                transcriber.onError = { [weak self] error in
                    Task { @MainActor in self?.handleError(error) }
                }
                sharedTranscriber = transcriber
                deepgramTranscriber = nil
                elevenLabsTranscriber = nil
                openAITranscriber = nil
                appleTranscriber = nil
                try await transcriber.start()
            } else {
                let transcriber = iOSLiveTranscriber(audioSessionManager: audioSessionManager)

                transcriber.onPartialResult = { [weak self] text, _ in
                    Task { @MainActor in
                        self?.handlePartialResult(text: text)
                    }
                }
                transcriber.onError = { [weak self] error in
                    Task { @MainActor in
                        self?.handleError(error)
                    }
                }

                appleTranscriber = transcriber
                deepgramTranscriber = nil
                elevenLabsTranscriber = nil
                openAITranscriber = nil
                sharedTranscriber = nil
                try await transcriber.start()
            }

            isRunning = true
        } catch {
            startTime = nil
            deepgramTranscriber = nil
            elevenLabsTranscriber = nil
            openAITranscriber = nil
            appleTranscriber = nil
            sharedTranscriber = nil
            sharedState.clearRecordingState()
            activityManager.endActivity()
            throw error
        }
    }

    /// Stops recording, applies the requested result destination, and returns the result.
    ///
    /// - Parameter destination: Where the transcript should go. When `nil`, defaults
    ///   to `.clipboardAndPostProcess` if the user has post-processing turned on,
    ///   else `.clipboard` — i.e., the original behaviour before destinations
    ///   were configurable. Hardware-trigger callers (Action Button, Siri,
    ///   Shortcuts) pass `AppSettings.shared.hardwareTriggerDestination`.
    @discardableResult
    public func stopRecording(destination: HardwareTriggerDestination? = nil) async -> TranscriptionResult {
        isRunning = false
        let duration = elapsedSeconds

        let result = await drainActiveTranscriber(duration: duration)
        startTime = nil

        // Record to history (always, regardless of destination).
        iOSHistoryManager.shared.recordTranscription(
            text: result.text,
            model: currentModel,
            duration: result.duration
        )

        // Resolve the destination. When nil (legacy callers), preserve the
        // pre-destination behaviour: clipboard + post-process if user opted in.
        let resolvedDestination: HardwareTriggerDestination = destination ?? .clipboard
        applyDestinationSideEffects(result: result, destination: resolvedDestination)

        // Update shared state
        sharedState.clearRecordingState()

        // Complete Live Activity with clipboard confirmation
        activityManager.completeActivity(finalWordCount: wordCount, duration: duration)

        // Kick off background post-processing if the chosen destination + user
        // settings call for it.
        if shouldPostProcess(destination: resolvedDestination, isLegacyCaller: destination == nil)
            && !result.text.isEmpty {
            Task { [resolvedDestination] in
                await postProcess(text: result.text, replacingClipboard: resolvedDestination != .historyOnly)
            }
        }

        return result
    }

    /// Cancels recording without saving.
    public func cancelRecording() {
        deepgramTranscriber?.cancel()
        elevenLabsTranscriber?.cancel()
        openAITranscriber?.cancel()
        appleTranscriber?.cancel()
        sharedTranscriber?.cancel()
        deepgramTranscriber = nil
        elevenLabsTranscriber = nil
        openAITranscriber = nil
        appleTranscriber = nil
        sharedTranscriber = nil
        isRunning = false
        startTime = nil
        partialText = ""
        wordCount = 0
        sharedState.clearRecordingState()
        activityManager.endActivity()
    }

    // MARK: - Private

    private func handlePartialResult(text: String) {
        partialText = text
        wordCount = text.split(separator: " ").count
        sharedState.updateTranscript(text)

        activityManager.updateActivity(
            status: .listening,
            lastSnippet: text,
            wordCount: wordCount,
            duration: elapsedSeconds
        )
    }

    private func handleError(_ error: Error) {
        activityManager.reportError(error.localizedDescription)
    }

    private func postProcess(text: String, replacingClipboard: Bool = true) async {
        let settings = AppSettings.shared
        let processor = iOSPostProcessingManager.shared

        await processor.process(
            text: text,
            model: settings.postProcessingModel,
            prompt: settings.postProcessingPrompt,
            apiKey: settings.openRouterAPIKey
        )

        // Replace clipboard with processed text (unless caller asked us not to).
        if !processor.processedText.isEmpty {
            if replacingClipboard {
                UIPasteboard.general.string = processor.processedText
            }
            sharedState.lastCompletedTranscript = processor.processedText
        }
    }
}

// MARK: - Stop helpers

@MainActor
private extension TranscriptionRecordingService {
    /// Stops whichever transcriber is currently active and returns its result.
    /// Falls back to a synthetic `TranscriptionResult` built from `partialText`
    /// if no transcriber is wired up (defensive — shouldn't happen in practice).
    ///
    /// We null out the transcriber property **before** awaiting `stop()` to be
    /// safe under `@MainActor` reentrancy: a rapid double-press of the Action
    /// Button can re-enter `stopRecording` while the first stop is suspended,
    /// and otherwise both calls would see the same non-nil transcriber and try
    /// to stop it twice.
    func drainActiveTranscriber(duration: Int) async -> TranscriptionResult {
        if let deepgram = deepgramTranscriber {
            deepgramTranscriber = nil
            return await deepgram.stop()
        }
        if let elevenlabs = elevenLabsTranscriber {
            elevenLabsTranscriber = nil
            return await elevenlabs.stop()
        }
        if let openai = openAITranscriber {
            openAITranscriber = nil
            return await openai.stop()
        }
        if let shared = sharedTranscriber {
            sharedTranscriber = nil
            return await shared.stop()
        }
        if let apple = appleTranscriber {
            appleTranscriber = nil
            return await apple.stop()
        }
        return TranscriptionResult(
            text: partialText,
            segments: [],
            confidence: nil,
            duration: TimeInterval(duration),
            modelIdentifier: currentModel,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }

    /// Applies the destination's side-effects (clipboard write, shared state
    /// update). History recording is handled by the caller because it always
    /// happens regardless of destination.
    func applyDestinationSideEffects(
        result: TranscriptionResult,
        destination: HardwareTriggerDestination
    ) {
        guard !result.text.isEmpty else { return }
        switch destination {
        case .clipboard, .clipboardAndPostProcess:
            UIPasteboard.general.string = result.text
            sharedState.lastCompletedTranscript = result.text
        case .historyOnly:
            // Don't touch the pasteboard. We still record `lastCompletedTranscript`
            // because the Live Activity / shared state UI shows it.
            sharedState.lastCompletedTranscript = result.text
        }
    }

    /// Decides whether to run the background post-processor.
    ///
    /// Two paths trigger it:
    /// 1. Legacy callers (no explicit destination) honour the global
    ///    `autoPostProcess` toggle for backwards compatibility.
    /// 2. Hardware-trigger callers explicitly choose `.clipboardAndPostProcess`.
    func shouldPostProcess(
        destination: HardwareTriggerDestination,
        isLegacyCaller: Bool
    ) -> Bool {
        let settings = AppSettings.shared
        switch destination {
        case .clipboardAndPostProcess:
            return settings.hasOpenRouterKey
        case .clipboard:
            return isLegacyCaller && settings.autoPostProcess && settings.hasOpenRouterKey
        case .historyOnly:
            return false
        }
    }
}
#endif
