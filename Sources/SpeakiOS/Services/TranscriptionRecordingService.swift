#if os(iOS)
import Foundation
import UIKit
import SpeakCore

// swiftlint:disable file_length

/// Headless recording coordinator for Action Button / Shortcuts / Siri.
/// Manages the full lifecycle: start recording → live transcription → stop → clipboard → Live Activity.
@MainActor
public final class TranscriptionRecordingService: ObservableObject { // swiftlint:disable:this type_body_length
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
    private var batchTranscriber: IOSBatchTranscriber?
    private var startTime: Date?
    private var currentModel: String = ""

    static let polishingClipboardPlaceholder = "Polishing… please wait"

    private init() {}

    /// Picks the first non-blank candidate, else the fallback. Extracted as a
    /// pure function so the stop-time text-selection priority
    /// (result → interim → last-completed) is unit-testable.
    static func bestTranscript(candidates: [String], fallback: String) -> String {
        for candidate in candidates
        where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return candidate
        }
        return fallback
    }

    private var elapsedSeconds: Int {
        guard let start = startTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    private var modelDisplayName: String {
        if batchTranscriber != nil { return ModelCatalog.friendlyName(for: currentModel) }
        if currentModel.hasPrefix("deepgram") { return "Deepgram" }
        if currentModel.hasPrefix("elevenlabs") { return "ElevenLabs" }
        if currentModel.hasPrefix("openai") { return "OpenAI gpt-realtime-whisper" }
        return "Apple Speech"
    }

    // MARK: - Public API

    /// Starts a headless recording session with Live Activity.
    public func startRecording() async throws {
        // swiftlint:disable:previous function_body_length
        guard !isRunning else { return }

        let settings = AppSettings.shared
        currentModel = settings.transcriptionMode == .batch
            ? settings.batchTranscriptionModel
            : settings.selectedModel
        partialText = ""
        wordCount = 0
        startTime = Date()
        sharedState.clear()
        sharedState.isRecording = true
        sharedState.recordingStartTime = startTime

        // Fall back to Apple Speech if the selected provider needs an API key we
        // don't have (covers every cloud provider via the shared routing).
        if settings.transcriptionMode == .streaming,
           let route = LiveTranscriptionRouting.route(for: currentModel),
           route.apiKeyIdentifier != nil,
           settings.liveAPIKey(for: route).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentModel = "apple/local/SFSpeechRecognizer"
        }

        // A Live Activity is required to record in the *background* via an
        // AudioRecordingIntent — without one the AppIntents system-policy check
        // asserts (EXC_BREAKPOINT). In the foreground a Live Activity is optional,
        // so only enforce this when the app isn't active.
        let activityStarted = activityManager.startActivity(provider: modelDisplayName)
        if !activityStarted && UIApplication.shared.applicationState != .active {
            startTime = nil
            sharedState.clearRecordingState()
            throw iOSTranscriptionError.liveActivityUnavailable
        }

        do {
            if settings.transcriptionMode == .batch {
                let transcriber = IOSBatchTranscriber(
                    audioSessionManager: audioSessionManager,
                    model: currentModel,
                    apiKey: settings.batchAPIKey
                )
                batchTranscriber = transcriber
                appleTranscriber = nil
                deepgramTranscriber = nil
                elevenLabsTranscriber = nil
                openAITranscriber = nil
                sharedTranscriber = nil
                try await transcriber.start()
            } else if currentModel.hasPrefix("deepgram") {
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
            batchTranscriber = nil
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

        // Keep the (often headless / backgrounded) process alive long enough for
        // the clipboard write — and any post-processing — to actually commit.
        // Short recordings were being suspended before the pasteboard flush
        // landed, so "Copied N words" was reported but nothing arrived.
        let assertion = beginBackgroundAssertion("Finalise transcription")

        if batchTranscriber != nil {
            activityManager.updateActivity(
                status: .processing,
                lastSnippet: "Transcribing recording…",
                wordCount: 0,
                duration: duration
            )
        }

        let drained = await drainActiveTranscriber(duration: duration)
        startTime = nil

        // Use the best available text and make the returned result, the history
        // entry, the clipboard, and the spoken dialog all agree on it.
        let text = bestAvailableText(from: drained)
        let result = drained.replacingText(text)
        partialText = text
        wordCount = text.split(whereSeparator: \.isWhitespace).count

        // Record to history (always, regardless of destination).
        let historyItem = iOSHistoryManager.shared.recordTranscription(
            text: text,
            model: currentModel,
            duration: result.duration
        )

        // Resolve the destination. When nil (legacy callers), preserve the
        // pre-destination behaviour: clipboard + post-process if user opted in.
        let resolvedDestination: HardwareTriggerDestination = destination ?? .clipboard
        await applyDestinationSideEffects(text: text, destination: resolvedDestination)

        // Update shared state
        sharedState.clearRecordingState()

        // Complete Live Activity with clipboard confirmation
        activityManager.completeActivity(finalWordCount: wordCount, duration: duration, keepPrimed: true)

        // Kick off background post-processing if the chosen destination + user
        // settings call for it. The polished clipboard write must also survive
        // process suspension, so the background assertion is released only once
        // post-processing has finished.
        if shouldPostProcess(destination: resolvedDestination, isLegacyCaller: destination == nil)
            && !text.isEmpty {
            if let historyItem {
                iOSHistoryManager.shared.beginPostProcessing(for: historyItem.id)
            }
            Task { [resolvedDestination, assertion] in
                await postProcess(
                    text: text,
                    historyItemID: historyItem?.id,
                    replacingClipboard: resolvedDestination != .historyOnly
                )
                assertion.end()
            }
        } else {
            assertion.end()
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
        batchTranscriber?.cancel()
        deepgramTranscriber = nil
        elevenLabsTranscriber = nil
        openAITranscriber = nil
        appleTranscriber = nil
        sharedTranscriber = nil
        batchTranscriber = nil
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

    private func postProcess(
        text: String,
        historyItemID: UUID?,
        replacingClipboard: Bool = true
    ) async {
        let settings = AppSettings.shared
        let processor = iOSPostProcessingManager.shared

        do {
            let polished = try await processor.polish(
                text: text,
                model: settings.postProcessingModel,
                prompt: settings.postProcessingPrompt,
                apiKey: settings.openRouterAPIKey
            )
            guard !polished.isEmpty else { throw PostProcessingError.emptyResult }
            if replacingClipboard {
                await Self.writeClipboardReliably(polished)
            }
            sharedState.lastCompletedTranscript = polished
            if let historyItemID {
                iOSHistoryManager.shared.setPostProcessed(polished, for: historyItemID)
            }
        } catch {
            // Never strand the user with the temporary polishing message.
            if replacingClipboard {
                await Self.writeClipboardReliably(text)
            }
            if let historyItemID {
                iOSHistoryManager.shared.setError(error.localizedDescription, for: historyItemID)
                iOSHistoryManager.shared.endPostProcessing(for: historyItemID)
            }
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
        if let batch = batchTranscriber {
            batchTranscriber = nil
            do {
                return try await batch.stop(language: Locale.current.identifier)
            } catch {
                handleError(error)
                return TranscriptionResult(
                    text: "",
                    segments: [],
                    confidence: nil,
                    duration: TimeInterval(duration),
                    modelIdentifier: currentModel,
                    cost: nil,
                    rawPayload: nil,
                    debugInfo: nil
                )
            }
        }
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
        text: String,
        destination: HardwareTriggerDestination
    ) async {
        guard !text.isEmpty else { return }
        switch destination {
        case .clipboard:
            await Self.writeClipboardReliably(text)
            sharedState.lastCompletedTranscript = text
        case .clipboardAndPostProcess:
            await Self.writeClipboardReliably(Self.polishingClipboardPlaceholder)
            sharedState.lastCompletedTranscript = text
        case .historyOnly:
            // Don't touch the pasteboard. We still record `lastCompletedTranscript`
            // because the Live Activity / shared state UI shows it.
            sharedState.lastCompletedTranscript = text
        }
    }

    /// Pasteboard writes from a background AppIntent can race process
    /// suspension. Verify the value and retry briefly before reporting success.
    static func writeClipboardReliably(_ text: String) async {
        for attempt in 0..<3 {
            UIPasteboard.general.string = text
            await Task.yield()
            if UIPasteboard.general.string == text { return }
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// The most complete transcript we can produce at stop time. The transcriber
    /// result is preferred, but for very short recordings the provider may return
    /// empty while interim text is still held in `partialText` — falling back
    /// there keeps the clipboard and dialog honest. We deliberately do NOT fall
    /// back to the last completed transcript: a silent new session must stay
    /// empty rather than re-emitting the previous recording's text.
    func bestAvailableText(from result: TranscriptionResult) -> String {
        TranscriptionRecordingService.bestTranscript(
            candidates: [result.text, partialText],
            fallback: result.text
        )
    }

    /// Begins a finite-length background assertion so a headless / backgrounded
    /// process isn't suspended before the clipboard (and any post-processing)
    /// write commits. The returned object ends the task exactly once.
    func beginBackgroundAssertion(_ name: String) -> BackgroundTaskAssertion {
        BackgroundTaskAssertion(name: name)
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

private extension TranscriptionResult {
    /// Returns a copy with `text` replaced, preserving all other metadata. Used
    /// so the returned result, history entry, clipboard, and spoken dialog all
    /// agree on the same best-available transcript.
    func replacingText(_ newText: String) -> TranscriptionResult {
        TranscriptionResult(
            text: newText,
            segments: segments,
            confidence: confidence,
            duration: duration,
            modelIdentifier: modelIdentifier,
            cost: cost,
            rawPayload: rawPayload,
            debugInfo: debugInfo
        )
    }
}

/// Reference-type wrapper around a UIKit background-task assertion that
/// guarantees `endBackgroundTask` is called exactly once — whether via the
/// normal completion path or the system expiration handler — avoiding the
/// double-end API violation.
@MainActor
final class BackgroundTaskAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
