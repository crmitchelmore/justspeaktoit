#if os(iOS)
import Foundation
import UIKit
import SpeakCore

// swiftlint:disable file_length

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

    private var transcriptionSession: IOSTranscriptionSession?
    private var startTime: Date?
    private var currentModel: String = ""
    private var sharesLiveTranscript = true

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
        ModelCatalog.transcriptionDisplayName(
            for: currentModel,
            isBatch: transcriptionSession?.isBatch
                ?? (AppSettings.shared.transcriptionMode == .batch)
        )
    }

    // MARK: - Public API

    /// Starts a headless recording session with Live Activity.
    public func startRecording( // swiftlint:disable:this function_body_length
        retainBatchRecording: Bool = true,
        sharesLiveTranscript: Bool = true,
        requiresLiveActivity: Bool = true
    ) async throws {
        guard !isRunning else { return }

        let settings = AppSettings.shared
        currentModel = settings.transcriptionMode == .batch
            ? settings.batchTranscriptionModel
            : settings.selectedModel
        partialText = ""
        wordCount = 0
        startTime = Date()
        self.sharesLiveTranscript = sharesLiveTranscript
        sharedState.clear()
        sharedState.isRecording = true
        sharedState.recordingStartTime = startTime

        if settings.transcriptionMode == .streaming {
            let route = LiveTranscriptionRouting.route(for: currentModel)
            currentModel = LiveTranscriptionRouting.resolvedModelID(
                for: currentModel,
                apiKey: route.map { settings.liveAPIKey(for: $0) }
            )
        }

        // A Live Activity is required to record in the *background* via an
        // AudioRecordingIntent — without one the AppIntents system-policy check
        // asserts (EXC_BREAKPOINT). In the foreground a Live Activity is optional,
        // so only enforce this when the app isn't active.
        let appIsActive = UIApplication.shared.applicationState == .active
        let activityStarted = (requiresLiveActivity || appIsActive)
            ? activityManager.startActivity(provider: modelDisplayName)
            : false
        if requiresLiveActivity && !activityStarted && !appIsActive {
            startTime = nil
            sharedState.clearRecordingState()
            throw iOSTranscriptionError.liveActivityUnavailable
        }

        #if DEBUG && targetEnvironment(simulator)
        if let transcript = sharedState.simulatorValidationTranscript {
            handlePartialResult(text: transcript)
            isRunning = true
            return
        }
        #endif

        do {
            let mode: IOSTranscriptionSession.Mode = settings.transcriptionMode == .batch
                ? .batch(retainRecording: retainBatchRecording)
                : .streaming
            let session = try IOSTranscriptionSession(
                modelID: currentModel,
                mode: mode,
                audioSessionManager: audioSessionManager,
                batchAPIKey: settings.batchAPIKey,
                liveAPIKey: settings.liveAPIKey(for:)
            )
            session.onPartialResult = { [weak self] text, _ in
                self?.handlePartialResult(text: text)
            }
            session.onError = { [weak self] error in
                self?.handleError(error)
            }
            transcriptionSession = session
            try await session.start()

            isRunning = true
        } catch {
            transcriptionSession?.cancel()
            startTime = nil
            transcriptionSession = nil
            self.sharesLiveTranscript = true
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
    public func stopRecording(
        destination: HardwareTriggerDestination? = nil,
        saveToHistory: Bool = true,
        primedActivityMessage: String = "Ready for the Action Button"
    ) async -> TranscriptionResult {
        isRunning = false
        let duration = elapsedSeconds

        // Keep the (often headless / backgrounded) process alive long enough for
        // the clipboard write — and any post-processing — to actually commit.
        // Short recordings were being suspended before the pasteboard flush
        // landed, so "Copied N words" was reported but nothing arrived.
        let assertion = beginBackgroundAssertion("Finalise transcription")

        if transcriptionSession?.isBatch == true {
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

        // Specialized callers may opt out when their result is intentionally transient.
        let historyItem = saveToHistory
            ? iOSHistoryManager.shared.recordTranscription(
                text: text,
                model: currentModel,
                duration: result.duration
            )
            : nil

        // Resolve the destination. When nil (legacy callers), preserve the
        // pre-destination behaviour: clipboard + post-process if user opted in.
        let resolvedDestination: HardwareTriggerDestination = destination ?? .clipboard
        await applyDestinationSideEffects(text: text, destination: resolvedDestination)

        // Update shared state
        sharedState.clearRecordingState()
        sharesLiveTranscript = true

        // Complete Live Activity with clipboard confirmation
        completeRecordingActivity(duration: duration, primedMessage: primedActivityMessage)

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

    private func completeRecordingActivity(duration: Int, primedMessage: String) {
        activityManager.completeActivity(
            finalWordCount: wordCount,
            duration: duration,
            keepPrimed: true,
            primedMessage: primedMessage
        )
    }

    /// Cancels recording without saving.
    public func cancelRecording() {
        transcriptionSession?.cancel()
        transcriptionSession = nil
        sharesLiveTranscript = true
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
        if sharesLiveTranscript {
            sharedState.updateTranscript(text)
        }

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
extension TranscriptionRecordingService {
    /// The pasteboard value that should be committed synchronously when the
    /// recording stops. Polishing gets a non-sensitive placeholder only when a
    /// post-processor can actually replace it; without a key, the raw transcript
    /// must be copied instead of leaving "Polishing… please wait" forever.
    static func clipboardTextAtStop(
        transcript: String,
        destination: HardwareTriggerDestination,
        canPostProcess: Bool
    ) -> String? {
        switch destination {
        case .clipboard:
            return transcript
        case .clipboardAndPostProcess:
            return canPostProcess ? polishingClipboardPlaceholder : transcript
        case .historyOnly:
            return nil
        }
    }

    static func legacySharedTranscript(_ transcript: String, sharesCompletedTranscript: Bool) -> String? {
        sharesCompletedTranscript ? transcript : nil
    }
}

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
        if let session = transcriptionSession {
            transcriptionSession = nil
            do {
                return try await session.stop(language: Locale.current.identifier)
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
        destination: HardwareTriggerDestination,
        sharesCompletedTranscript: Bool? = nil
    ) async {
        guard !text.isEmpty else { return }
        if let clipboardText = Self.clipboardTextAtStop(
            transcript: text,
            destination: destination,
            canPostProcess: AppSettings.shared.hasOpenRouterKey
        ) {
            await Self.writeClipboardReliably(clipboardText)
        }

        // Keyboard handoffs keep their result solely in the nonce-scoped store.
        // Other destinations publish the completed transcript so the Live
        // Activity and foreground handoff can surface it.
        if let sharedTranscript = Self.legacySharedTranscript(
            text,
            sharesCompletedTranscript: sharesCompletedTranscript ?? sharesLiveTranscript
        ) {
            sharedState.lastCompletedTranscript = sharedTranscript
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
