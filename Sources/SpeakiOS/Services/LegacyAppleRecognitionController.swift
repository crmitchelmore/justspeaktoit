#if os(iOS)
import AVFoundation
import Foundation
import Speech
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "iOSLiveTranscriber")

/// What the legacy recogniser needs from the transcriber that owns the capture.
@MainActor
protocol LegacyAppleRecognitionHost: AnyObject {
    /// True while `captureID` is still the owner's live capture; a Cancel or a
    /// replacement start retires it.
    func isCurrentCapture(_ captureID: UUID) -> Bool
    var isCaptureRunning: Bool { get }
    var isCaptureStopping: Bool { get }
    func publishTranscript(_ text: String, isFinal: Bool, confidence: Double?)
    func legacyRecognitionDidFail(_ error: Error)
    func reportEngineStarted(_ backend: StartupBackend)
    /// Called when the tap could not be reinstalled after a restart.
    func legacyTapWasRejected()
    /// The render-thread first-input callback for `captureID` (issue #983).
    func firstInputReporter(captureID: UUID?) -> () -> Void
}

/// Owns the legacy `SFSpeechRecognizer` path for ``iOSLiveTranscriber``: the
/// recogniser, its request and task, the per-task identity that drops stale
/// callbacks, the restart after a mid-session `isFinal`, the bounded wait for
/// the final callback on Stop, and the transcript assembly.
///
/// The host owns the capture identity and the published state; the engine,
/// tap queue and recorder are shared with it. Every callback
/// is checked against both the capture identity and this task's identity, so
/// a cancelled or replaced run can never write into the current one.
@MainActor
final class LegacyAppleRecognitionController {
    weak var host: LegacyAppleRecognitionHost?

    var preferOnDevice = true
    /// Hard privacy requirement for routes that promise local processing.
    var requiresStrictOnDeviceRecognition = false
    /// Replaces the framework recogniser in lifecycle tests.
    var recognitionStart: ((@escaping (LegacyAppleRecognitionUpdate?, Error?) -> Void)
        -> LegacyAppleRecognitionTask)?
    /// Capability seam for tests that replace the entire legacy recognizer.
    /// Production leaves it nil and checks the concrete recognizer directly.
    var injectedCapability: (() -> AppleLocalRecognitionCapability)?
    let finalisation = LegacyAppleFinalisationGate()

    private(set) var assembly = LegacyAppleTranscriptAssembly()
    private let input: LiveCaptureInput
    private let tap: AppleSpeechCaptureTap
    private let recorder: AudioRecordingPersistence
    private let recordingLoss: RecordingLossReporting
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: LegacyAppleRecognitionTask?
    private var activeRecognitionID: UUID?
    private var isShuttingDown = false

    private static let assistantErrorDomain = "kAFAssistantErrorDomain"
    private static let cancelledTaskErrorCode = 209

    init(
        input: LiveCaptureInput, tap: AppleSpeechCaptureTap,
        recorder: AudioRecordingPersistence, recordingLoss: RecordingLossReporting
    ) {
        self.input = input
        self.tap = tap
        self.recorder = recorder
        self.recordingLoss = recordingLoss
    }

    func reset() {
        assembly = LegacyAppleTranscriptAssembly()
        isShuttingDown = false
    }

    func requireInjectedCapabilityIfStrict() throws {
        guard requiresStrictOnDeviceRecognition else { return }
        guard injectedCapability?() == .available else {
            throw iOSTranscriptionError.offlineLocalRecognitionUnavailable
        }
    }

    // MARK: - Start

    /// Starts legacy capture for `captureID`: the recogniser, the safety
    /// writer, the tap and the engine, then the first recognition task. The
    /// injected test recogniser replaces everything but the task.
    func startCapture(captureID: UUID, language: String) throws {
        if recognitionStart != nil {
            try requireInjectedCapabilityIfStrict()
        } else {
            let request = try prepare(language: language)
            // The safety writer opens before the tap and the engine, so the file
            // covers the very first buffers instead of starting a beat late
            // (issue #992); a writer failure is reported, never fatal (issue #950).
            recordingLoss.startWriter(recorder, format: input.inputNode.outputFormat(forBus: 0))
            try installTap(appendingTo: request, captureID: captureID)
            try input.startEngine()
            host?.reportEngineStarted(.appleLegacy)
        }
        beginTask(captureID: captureID)
    }

    /// Installs the input tap appending to `request`. The request is captured
    /// immutably so the audio-thread tap never reads `recognitionRequest`,
    /// which is replaced on restart.
    private func installTap(appendingTo request: SFSpeechAudioBufferRecognitionRequest, captureID: UUID) throws {
        let recorder = recorder
        try tap.install(
            on: input, bufferSize: 1024,
            lossReport: recordingLoss.currentReport,
            onFirstInput: host?.firstInputReporter(captureID: captureID) ?? {}
        ) { buffer in
            request.append(buffer)
            recorder.writeBuffer(buffer)
        }
    }

    /// Builds the framework recogniser and request for `language`.
    private func prepare(language: String) throws -> SFSpeechAudioBufferRecognitionRequest {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.isAvailable else {
            SpeakLogger.transcription.error("Speech recognizer unavailable for language: \(language, privacy: .public)")
            throw iOSTranscriptionError.recognizerUnavailable
        }
        speechRecognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request
        request.shouldReportPartialResults = true
        if try requiresOnDevice(recognizer) {
            request.requiresOnDeviceRecognition = true
            SpeakLogger.transcription.info("Using on-device recognition")
        } else {
            SpeakLogger.transcription.info("Using server-based recognition")
        }
        return request
    }

    /// Starts a recognition task for `captureID` on the prepared request, or
    /// on the injected recogniser in tests.
    private func beginTask(captureID: UUID) {
        let recognitionID = UUID()
        activeRecognitionID = recognitionID
        isShuttingDown = false
        let receive: (LegacyAppleRecognitionUpdate?, Error?) -> Void = { [weak self] result, error in
            guard let self, self.host?.isCurrentCapture(captureID) == true,
                  self.activeRecognitionID == recognitionID else { return }
            self.handle(result, error: error, captureID: captureID)
        }
        if let recognitionStart {
            recognitionTask = recognitionStart(receive)
        } else if let recognizer = speechRecognizer, let request = recognitionRequest {
            let task = recognizer.recognitionTask(with: request) { result, error in
                let update = result.map(LegacyAppleRecognitionUpdate.init)
                Task { @MainActor in receive(update, error) }
            }
            recognitionTask = LegacyAppleRecognitionTask(
                endAudio: request.endAudio, finish: task.finish, cancel: task.cancel
            )
        }
    }

    // MARK: - Stop and cancel

    /// Stops `captureID`: input first, then the buffers already queued reach
    /// the request — `endAudio()` before that drain would discard the last
    /// words spoken — then a bounded wait for the task's terminal callback,
    /// and the recording is closed. Returns the duration, or nil when a Cancel
    /// retired the capture during either suspension.
    func stop(captureID: UUID?, lossRun: RecordingLossReport, since startTime: Date?) async -> TimeInterval? {
        isShuttingDown = true
        input.halt()
        await tap.drainPendingWork()
        guard let captureID, host?.isCurrentCapture(captureID) == true else { return nil }
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        await endAudioAndAwaitFinalisation(captureID: captureID)
        guard host?.isCurrentCapture(captureID) == true else { return nil }
        activeRecognitionID = nil
        recognitionTask?.cancel()
        recordingLoss.finish(recorder: recorder, run: lossRun)
        return duration
    }

    /// Ends the audio and waits, bounded, for the task's terminal callback.
    private func endAudioAndAwaitFinalisation(captureID: UUID) async {
        recognitionTask?.endAudio()
        // A terminal callback may already have arrived during the buffer drain.
        guard let recognitionID = activeRecognitionID, let recognitionTask else { return }
        await finalisation.wait(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.host?.isCurrentCapture(captureID) == true && self.activeRecognitionID == recognitionID
        }, finish: recognitionTask.finish)
    }

    /// Retires the current task's identity so no further callback is applied,
    /// and releases any Stop that is waiting for it.
    func retire() {
        activeRecognitionID = nil
        finalisation.complete()
    }

    /// Ends and cancels the current task (Cancel), then releases it.
    func tearDown() {
        isShuttingDown = true
        recognitionTask?.endAudio()
        recognitionTask?.cancel()
        release()
    }

    func release() {
        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
    }

    // MARK: - Callbacks

    private func handle(_ result: LegacyAppleRecognitionUpdate?, error: Error?, captureID: UUID) {
        let terminal = result?.isFinal == true || error != nil
        if terminal { activeRecognitionID = nil }
        if let result, let text = assembly.receive(result, terminal: terminal) {
            host?.publishTranscript(text, isFinal: result.isFinal, confidence: result.confidence)
        }
        // Callbacks can synchronously Cancel; never resume/restart that capture.
        guard let host, host.isCurrentCapture(captureID) else { return }
        if terminal { finalisation.complete() }
        if let error {
            let nsError = error as NSError
            if nsError.domain == Self.assistantErrorDomain,
               nsError.code == Self.cancelledTaskErrorCode,
               isShuttingDown || !host.isCaptureRunning { return }
            logger.error("Recognition error: \(error.localizedDescription, privacy: .public)")
            host.legacyRecognitionDidFail(iOSTranscriptionError.recognitionFailed(error))
        } else if result?.isFinal == true, !host.isCaptureStopping {
            restart(captureID: captureID)
        }
    }

    /// Restart recognition after a mid-session `isFinal` so continued speech
    /// is captured without losing previously committed text.
    private func restart(captureID: UUID) {
        guard let host, host.isCaptureRunning, !host.isCaptureStopping, host.isCurrentCapture(captureID),
              speechRecognizer != nil || recognitionStart != nil else { return }

        isShuttingDown = true
        assembly.keepLatestSegments()

        // Let buffers already queued reach the *old* request before its task is
        // cancelled — the tap captured that request immutably, so anything still
        // queued would otherwise be appended to a dead request and dropped.
        // The drain is synchronous because the restart must stay atomic on the
        // main actor; the queued work is an append plus a buffer copy, and
        // nothing on that queue ever waits on the main actor.
        tap.drainSynchronously()

        recognitionTask?.cancel()
        recognitionTask = nil
        assembly.beginNextTask()
        if recognitionStart != nil {
            do {
                try requireInjectedCapabilityIfStrict()
            } catch {
                host.legacyRecognitionDidFail(error)
                return
            }
            beginTask(captureID: captureID)
            return
        }
        guard let recognizer = speechRecognizer else { return }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        do {
            if try requiresOnDevice(recognizer) {
                newRequest.requiresOnDeviceRecognition = true
            }
        } catch {
            host.legacyRecognitionDidFail(error)
            return
        }
        recognitionRequest = newRequest

        // Reinstall the tap so its closure captures the new request; the old
        // tap holds the previous (cancelled) request immutably.
        input.removeTap()
        do {
            try installTap(appendingTo: newRequest, captureID: captureID)
        } catch {
            // A rejected tap means the input format changed under the running
            // engine; end capture through the owner's normal stop path.
            host.legacyTapWasRejected()
            return
        }
        beginTask(captureID: captureID)
    }

    private func requiresOnDevice(_ recognizer: SFSpeechRecognizer) throws -> Bool {
        let capability: AppleLocalRecognitionCapability = recognizer.supportsOnDeviceRecognition
            ? .available : .unavailable
        return try AppleLegacyRecognitionRequestPolicy.requiresOnDeviceRecognition(
            strict: requiresStrictOnDeviceRecognition,
            preferred: preferOnDevice,
            capability: capability
        )
    }
}

/// The bounded wait for the legacy recogniser's terminal callback on Stop.
@MainActor
final class LegacyAppleFinalisationGate {
    /// Cap the recognizer wait at two seconds after queued audio drains, keeping
    /// an unresponsive framework from holding Stop indefinitely. Return early on
    /// a terminal callback; this ceiling still needs device latency validation.
    /// Device latency/trailing-word coverage is tracked in issue #948.
    var scheduleDeadline: (@escaping () -> Void) -> (() -> Void) = { completion in
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            completion()
        }
        return { task.cancel() }
    }
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancelDeadline: (() -> Void)?

    /// Calls `finish` and suspends until ``complete()`` or the deadline. The
    /// deadline only completes while `isCurrent` still holds.
    func wait(isCurrent: @escaping () -> Bool, finish: () -> Void) async {
        let beganWaiting = Date()
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            cancelDeadline = scheduleDeadline { [weak self] in
                guard let self, isCurrent() else { return }
                logger.warning("Legacy Apple finalisation deadline reached; retaining the latest usable result")
                self.complete()
            }
            finish()
        }
        let elapsed = Date().timeIntervalSince(beganWaiting)
        logger.info("Legacy Apple finalisation wait: \(elapsed, privacy: .public)s")
    }

    func complete() {
        cancelDeadline?()
        cancelDeadline = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}
#endif
