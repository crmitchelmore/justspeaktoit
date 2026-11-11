#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// One running SpeechAnalyzer capture for ``iOSLiveTranscriber``: the
/// analyzer session and the converter its tap feeds.
///
/// ``start(_:)`` owns the whole setup in one do/catch: on any failure it stops
/// the engine, removes the tap, drains the queue, discards the recording and
/// cancels the session, so the transcriber only ever holds a capture that
/// actually started.
@available(iOS 26.0, *)
@MainActor
final class AppleSpeechAnalyzerCapture {
    struct Setup {
        let localeIdentifier: String
        let engine: AppleSpeechAnalyzerEngine
        let preRollBuffers: [AVAudioPCMBuffer]
        let input: LiveCaptureInput
        let tap: AppleSpeechCaptureTap
        let recorder: AudioRecordingPersistence
        let recordingLoss: RecordingLossReporting
        let onFirstInput: () -> Void
        /// Runs once the engine has actually returned (issue #972).
        let onEngineStarted: @MainActor () -> Void
        let onUpdate: @Sendable (AppleSpeechAnalyzerUpdate) -> Void
    }

    let session: AppleSpeechAnalyzerLiveSession
    private let converter: AppleSpeechAudioConverter
    private let setup: Setup

    private init(session: AppleSpeechAnalyzerLiveSession, converter: AppleSpeechAudioConverter, setup: Setup) {
        self.session = session
        self.converter = converter
        self.setup = setup
    }

    var modelIdentifier: String { session.modelIdentifier }

    struct FinishFailure: Error {
        let error: Error
        /// Measured once the recording was closed.
        let elapsed: TimeInterval
    }

    /// Stops input, lets queued buffers reach the analyser and the recorder,
    /// closes the recording, then finishes the session. The result lasts at
    /// least as long as the capture did.
    func finish(since startTime: Date?) async -> Result<TranscriptionResult, FinishFailure> {
        let lossRun = setup.recordingLoss.currentReport
        setup.input.halt()
        await setup.tap.drainPendingWork()
        setup.recordingLoss.finish(recorder: setup.recorder, run: lossRun)
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        do {
            let result = try await session.finish()
            return .success(TranscriptionResult(
                text: result.text, segments: result.segments, confidence: result.confidence,
                duration: max(elapsed, result.duration), modelIdentifier: modelIdentifier,
                cost: nil, rawPayload: nil, debugInfo: nil
            ))
        } catch {
            return .failure(FinishFailure(error: error, elapsed: elapsed))
        }
    }

    /// Discards the session after a Cancel; the caller awaits the returned task
    /// before a new start.
    func cancel() -> Task<Void, Never> {
        let session = session
        return Task { await session.cancel() }
    }

    /// Decides what a failed analyzer start leads to. Cancellation is a
    /// control action, never a reason to activate the legacy recognizer after
    /// the user stopped, so it is rethrown; so is the failure when fallback is
    /// not allowed. Otherwise returns whether the analyzer assets were missing.
    static func assetsMissingForFallback(after error: Error, fallbackAllowed: Bool) throws -> Bool {
        if Task.isCancelled || error is CancellationError { throw CancellationError() }
        let context = "SpeechAnalyzer setup; falling back to SFSpeechRecognizer"
        SpeakLogger.logError(error, context: context, logger: SpeakLogger.transcription)
        var assetsMissing = false
        if case AppleLocalModelError.modelAssetsUnavailable = error { assetsMissing = true }
        guard fallbackAllowed else { throw assetsMissing ? AppleSpeechReadiness.modelPreparationError : error }
        return assetsMissing
    }

    static func start(_ setup: Setup) async throws -> AppleSpeechAnalyzerCapture {
        let session = try await AppleSpeechAnalyzerLiveSession(
            localeIdentifier: setup.localeIdentifier,
            engine: setup.engine,
            assetPolicy: .installedOnly,
            onUpdate: setup.onUpdate
        )
        do {
            try Task.checkCancellation()
            let recordingFormat = setup.input.inputNode.outputFormat(forBus: 0)
            let converter = try AppleSpeechAudioConverter(
                sourceFormat: recordingFormat,
                targetFormat: session.audioFormat
            )
            let recorder = setup.recorder
            try setup.tap.install(
                on: setup.input, bufferSize: 4096,
                lossReport: setup.recordingLoss.currentReport, onFirstInput: setup.onFirstInput
            ) { buffer in
                recorder.writeBuffer(buffer)
                guard let converted = converter.convert(buffer) else { return }
                session.send(converted)
            }
            setup.recordingLoss.startWriter(recorder, format: recordingFormat)
            for buffer in setup.preRollBuffers {
                if let converted = converter.convert(buffer) {
                    session.send(converted)
                }
            }
            try setup.input.startEngine()
            setup.onEngineStarted()
            return AppleSpeechAnalyzerCapture(session: session, converter: converter, setup: setup)
        } catch {
            setup.input.halt()
            setup.tap.drainSynchronously()
            setup.recorder.cancelRecording()
            await session.cancel()
            throw error
        }
    }
}
#endif
