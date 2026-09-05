#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// Records a complete audio file and uploads it after the user stops recording.
/// Batch mode deliberately has no interim transcript: its result arrives once
/// the selected remote model has processed the saved recording.
@MainActor
public final class IOSBatchTranscriber {
    private let audioSessionManager: AudioSessionManager
    private let startup = RecordingStartupOperation()
    private var ownsAudioSession = false
    private var hasInputTap = false

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        audioSessionManager.deactivate()
        ownsAudioSession = false
    }

    private func removeInputTap() {
        guard hasInputTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        hasInputTap = false
    }
    private let audioEngine = AVAudioEngine()
    private let audioRecorder = AudioRecordingPersistence()
    private let client: IOSBatchTranscriptionClient
    private let retainRecording: Bool
    private var startTime: Date?

    public let model: String

    public init(
        audioSessionManager: AudioSessionManager,
        model: String,
        apiKey: String,
        keywords: [String] = [],
        retainRecording: Bool = true,
        session: URLSession = .shared
    ) {
        self.audioSessionManager = audioSessionManager
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.retainRecording = retainRecording
        self.client = IOSBatchTranscriptionClient(apiKey: apiKey, keywords: keywords, session: session)
    }

    public func start() async throws {
        guard startTime == nil, !startup.isStarting else { return }
        do {
            try await startup.run(
                { try await self.startCapture() },
                onFailure: { self.cleanupCapture() }
            )
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    private func startCapture() async throws {
        let permissionGranted = await ensureMicrophonePermission()
        try Task.checkCancellation()
        guard permissionGranted else {
            throw iOSTranscriptionError.permissionDenied(.microphone)
        }
        ownsAudioSession = true
        try await audioSessionManager.configureForRecording()
        try Task.checkCancellation()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        try audioRecorder.startRecording(format: format)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [audioRecorder] buffer, _ in
            audioRecorder.writeBuffer(buffer)
        }
        hasInputTap = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            startTime = Date()
        } catch {
            removeInputTap()
            audioRecorder.cancelRecording()
            releaseAudioSession()
            throw error
        }
    }

    public func stop(language: String?) async throws -> TranscriptionResult {
        audioEngine.stop()
        removeInputTap()
        guard let recording = audioRecorder.stopRecording() else {
            releaseAudioSession()
            throw IOSBatchTranscriptionError.missingRecording
        }
        releaseAudioSession()
        startTime = nil

        // A non-retained recording is temporary, but it is still the only copy
        // of what the user said. Delete it after the transcript is safely in
        // hand, never on the error path: the keyboard reports the failure to
        // the user, and the preserved file stays visible in the Recordings
        // screen, which lists every file in the recordings directory. From
        // there the user can play it back, retry it, or delete it.
        let result = try await client.transcribeFile(
            at: recording.url,
            model: model,
            language: language
        )
        if !retainRecording {
            AudioRecordingPersistence.deleteRecording(at: recording.url)
        }
        return result
    }

    public func cancel() {
        startup.cancel()
        cleanupCapture()
    }

    private func cleanupCapture() {
        audioEngine.stop()
        removeInputTap()
        audioRecorder.cancelRecording()
        releaseAudioSession()
        startTime = nil
    }

    private func ensureMicrophonePermission() async -> Bool {
        if audioSessionManager.hasMicrophonePermission() { return true }
        return await audioSessionManager.requestMicrophonePermission()
    }

    /// One-shot transcription of an existing audio file, reusing the same
    /// batch client the record-and-upload path uses. Used by callers that
    /// supply their own file instead of recording one: the Transcribe Audio
    /// File App Intent (Shortcuts), and audio captured on Apple Watch and
    /// delivered via WatchConnectivity.
    public static func transcribeFile(
        at url: URL,
        model: String,
        apiKey: String,
        language: String?,
        keywords: [String] = [],
        session: URLSession = .shared
    ) async throws -> TranscriptionResult {
        try await IOSBatchTranscriptionClient(apiKey: apiKey, keywords: keywords, session: session)
            .transcribeFile(at: url, model: model, language: language)
    }
}

/// Which upload path a batch model takes on iOS.
///
/// A named decision rather than a chain of `if`s inside the request path, so
/// the routing is assertable without a network round trip and adding a
/// provider is one case rather than one more branch.
enum IOSBatchTranscriptionRoute: Equatable, Sendable {
    case appleSpeechAnalyzer
    case openAI
    case metaMuse
    case cartesia
    /// Google's own Interactions API, through the shared
    /// `GeminiInteractionsClient`. Matched on the direct-batch identifiers
    /// only: the `google/gemini-2.0-flash-*` catalogue entries share the
    /// `google/` prefix but are OpenRouter-routed.
    case gemini
    case openRouter

    static func route(for model: String) -> IOSBatchTranscriptionRoute {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if AppleLocalModels.isSpeechAnalyzerModel(model) { return .appleSpeechAnalyzer }
        if AppSettings.openAIBatchModelIDs.contains(model) { return .openAI }
        if model == CartesiaBatchClient.catalogID { return .cartesia }
        if model == MetaMuseVoiceTranscribe.batchCatalogID { return .metaMuse }
        if GeminiTranscribeModels.directBatchModelIDs.contains(model) { return .gemini }
        return .openRouter
    }
}

#endif
