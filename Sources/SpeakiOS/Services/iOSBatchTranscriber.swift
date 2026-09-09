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
    /// Batch has no live partial result, so its input tap is the only signal
    /// that capture is really running. Replaced per start so a retired run's
    /// tap can never report input for the run that replaced it (issue #983).
    private var firstInputSignal = FirstInputSignal()
    private var activeCaptureID: UUID?

    /// Raised on the main actor at most once per start, when this run's own
    /// input tap accepts a buffer with a positive frame count.
    public var onFirstInputBuffer: (() -> Void)?
    /// Local startup-boundary observations for this start (issue #972). Batch
    /// has no live partial, so its timeline ends at the session start.
    public var onStartupObservation: ((StartupObservation) -> Void)?

    /// Hopped to from the audio thread once, never per buffer.
    private func reportFirstInputBuffer(_ captureID: UUID) {
        guard activeCaptureID == captureID else { return }
        onFirstInputBuffer?()
    }

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
    let audioRecorder = AudioRecordingPersistence()
    private let client: IOSBatchTranscriptionClient
    private let retainRecording: Bool
    private var startTime: Date?
    /// The completed file this capture wrote, from `stop()` closing it until
    /// its owner discards it. `nil` for a retained recording's lifetime is
    /// meaningless: `discardRecordingIfNotRetained` never deletes one the user
    /// asked to keep.
    public private(set) var finishedRecordingURL: URL?

    /// Whether this capture's recording is the user's to keep.
    public var retainsRecording: Bool { retainRecording }

    /// The safety claim this capture's recording was written under, if any.
    public var safetyRecordingID: UUID? { audioRecorder.lastClaim }

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
        let captureID = UUID()
        activeCaptureID = captureID
        firstInputSignal = FirstInputSignal()
        let permissionGranted = await ensureMicrophonePermission()
        try Task.checkCancellation()
        guard permissionGranted else {
            throw iOSTranscriptionError.permissionDenied(.microphone)
        }
        ownsAudioSession = true
        try await audioSessionManager.configureForRecording()
        onStartupObservation?(.stage(.audioSessionConfigured))
        try Task.checkCancellation()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        try audioRecorder.startRecording(format: format)
        let signal = firstInputSignal
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [audioRecorder, weak self] buffer, _ in
            audioRecorder.writeBuffer(buffer)
            guard buffer.frameLength > 0, signal.markObserved() else { return }
            Task { @MainActor [weak self] in self?.reportFirstInputBuffer(captureID) }
        }
        hasInputTap = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            // Only after the engine actually returned.
            onStartupObservation?(.stage(.engineStarted))
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
        activeCaptureID = nil
        startTime = nil
        guard let recording = audioRecorder.stopRecording() else {
            releaseAudioSession()
            throw IOSBatchTranscriptionError.missingRecording
        }
        releaseAudioSession()

        // A non-retained recording is temporary, but it is still the only copy
        // of what the user said, and a transcript in hand is not a transcript
        // delivered. Deleting here lost the audio whenever the caller never
        // used this result — a finalisation deadline that already gave up on
        // the stop, or a process killed between this reply and the History
        // write. The file is therefore kept until its owner says delivery of
        // this capture is complete (`discardRecordingIfNotRetained`), and kept
        // for good on the error path: the keyboard reports the failure to the
        // user, and the preserved file stays visible in the Recordings screen,
        // which lists every file in the recordings directory. From there the
        // user can play it back, retry it, or delete it.
        finishedRecordingURL = recording.url
        return try await client.transcribeFile(
            at: recording.url,
            model: model,
            language: language
        )
    }

    /// Discards the temporary recording of a capture whose transcript has been
    /// delivered. Called by the owner of the result, never by the upload — a
    /// result nobody used must leave its audio recoverable.
    ///
    /// - Returns: `true` when a file was actually removed.
    @discardableResult
    public func discardRecordingIfNotRetained() -> Bool {
        guard !retainRecording, let url = finishedRecordingURL else { return false }
        finishedRecordingURL = nil
        AudioRecordingPersistence.deleteRecording(at: url)
        // The file is gone, so its claim has nothing left to point at
        // (issue #992). The transcript was delivered before this ran.
        audioRecorder.forgetLastClaim()
        return true
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
        activeCaptureID = nil
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
    case azure
    case cartesia
    /// Gladia's asynchronous pre-recorded job API, through the shared
    /// `GladiaBatchClient` with the `gladia.apiKey` this app already stores for
    /// the live Solaria provider.
    case gladia
    /// Google's own Interactions API, through the shared
    /// `GeminiInteractionsClient`. Matched on the direct-batch identifiers
    /// only: the `google/gemini-2.0-flash-*` catalogue entries share the
    /// `google/` prefix but are OpenRouter-routed.
    case gemini
    /// xAI's dedicated speech-to-text endpoint, through the shared
    /// `XAIBatchTranscriptionClient`. The Grok Voice streaming identifier
    /// shares the `xai/` prefix but has no file mode, so this matches on the
    /// batch identifier alone.
    case xai
    case openRouter

    static func route(for model: String) -> IOSBatchTranscriptionRoute {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if AppleLocalModels.isSpeechAnalyzerModel(model) { return .appleSpeechAnalyzer }
        if AppSettings.openAIBatchModelIDs.contains(model) { return .openAI }
        if model == CartesiaBatchClient.catalogID { return .cartesia }
        if model == GladiaBatchClient.catalogID { return .gladia }
        if AzureTranscriptionModels.batchIDs.contains(model) { return .azure }
        if model == MetaMuseVoiceTranscribe.batchCatalogID { return .metaMuse }
        if GeminiTranscribeModels.directBatchModelIDs.contains(model) { return .gemini }
        if model == XAISpeechToText.batchCatalogID { return .xai }
        return .openRouter
    }
}

#endif
