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
    private var startTime: Date?

    private init() {}

    private var elapsedSeconds: Int {
        guard let start = startTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    private var modelDisplayName: String {
        let model = AppSettings.shared.selectedModel
        if model.hasPrefix("deepgram") { return "Deepgram" }
        return "Apple Speech"
    }

    // MARK: - Public API

    /// Starts a headless recording session with Live Activity.
    public func startRecording() async throws {
        guard !isRunning else { return }

        let settings = AppSettings.shared
        var model = settings.selectedModel
        partialText = ""
        wordCount = 0
        startTime = Date()
        sharedState.clear()
        sharedState.isRecording = true
        sharedState.recordingStartTime = startTime

        // Fallback to Apple Speech if Deepgram selected but no API key
        if model.hasPrefix("deepgram") && !settings.hasDeepgramKey {
            model = "apple/local/SFSpeechRecognizer"
        }

        // Live Activity is mandatory for AudioRecordingIntent
        activityManager.startActivity(provider: modelDisplayName)

        if model.hasPrefix("deepgram") {
            let transcriber = DeepgramLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.configure(apiKey: settings.deepgramAPIKey)
            transcriber.model = model.replacingOccurrences(of: "deepgram/", with: "")

            transcriber.onPartialResult = { [weak self] text, isFinal in
                self?.handlePartialResult(text: self?.deepgramTranscriber?.partialText ?? text)
            }
            transcriber.onError = { [weak self] error in
                self?.handleError(error)
            }

            deepgramTranscriber = transcriber
            appleTranscriber = nil
            try await transcriber.start()
        } else {
            let transcriber = iOSLiveTranscriber(audioSessionManager: audioSessionManager)

            transcriber.onPartialResult = { [weak self] text, isFinal in
                self?.handlePartialResult(text: self?.appleTranscriber?.partialText ?? text)
            }
            transcriber.onError = { [weak self] error in
                self?.handleError(error)
            }

            appleTranscriber = transcriber
            deepgramTranscriber = nil
            try await transcriber.start()
        }

        isRunning = true
    }

    /// Stops recording, copies transcript to clipboard, and returns the result.
    @discardableResult
    public func stopRecording() async -> TranscriptionResult {
        isRunning = false
        let duration = elapsedSeconds
        let model = AppSettings.shared.selectedModel

        let result: TranscriptionResult
        if let deepgram = deepgramTranscriber {
            result = await deepgram.stop()
            deepgramTranscriber = nil
        } else if let apple = appleTranscriber {
            result = await apple.stop()
            appleTranscriber = nil
        } else {
            result = TranscriptionResult(
                text: partialText,
                segments: [],
                confidence: nil,
                duration: TimeInterval(duration),
                modelIdentifier: model,
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        }

        startTime = nil

        // Record to history
        iOSHistoryManager.shared.recordTranscription(
            text: result.text,
            model: model,
            duration: result.duration
        )

        // Copy to clipboard immediately
        if !result.text.isEmpty {
            UIPasteboard.general.string = result.text
            sharedState.lastCompletedTranscript = result.text
        }

        // Update shared state
        sharedState.clearRecordingState()

        // Complete Live Activity with clipboard confirmation
        activityManager.completeActivity(finalWordCount: wordCount, duration: duration)

        // Post-process in background if enabled
        if AppSettings.shared.autoPostProcess && AppSettings.shared.hasOpenRouterKey && !result.text.isEmpty {
            Task {
                await postProcess(text: result.text)
            }
        }

        return result
    }

    /// Cancels recording without saving.
    public func cancelRecording() {
        deepgramTranscriber?.cancel()
        appleTranscriber?.cancel()
        deepgramTranscriber = nil
        appleTranscriber = nil
        isRunning = false
        startTime = nil
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

    private func postProcess(text: String) async {
        let settings = AppSettings.shared
        let processor = iOSPostProcessingManager.shared

        await processor.process(
            text: text,
            model: settings.postProcessingModel,
            prompt: settings.postProcessingPrompt,
            apiKey: settings.openRouterAPIKey
        )

        // Replace clipboard with processed text
        if !processor.processedText.isEmpty {
            UIPasteboard.general.string = processor.processedText
            sharedState.lastCompletedTranscript = processor.processedText
        }
    }
}
#endif
