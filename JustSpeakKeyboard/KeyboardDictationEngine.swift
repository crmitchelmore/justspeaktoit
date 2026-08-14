import AVFoundation
import Foundation
import Speech
import SpeakCore

@MainActor
protocol KeyboardDictationEngineProtocol: AnyObject {
    var onEvent: ((UUID, KeyboardDictationMachine.Event) -> Void)? { get set }

    func start(runID: UUID, localeIdentifier: String)
    func stop(runID: UUID)
    func cancel(runID: UUID)
}

/// Captures microphone audio and produces live Apple Speech hypotheses inside
/// the keyboard extension process.
///
/// This requires the user to grant the keyboard Full Access plus microphone
/// and speech-recognition permission. Recognition prefers on-device Apple
/// Speech when the locale supports it; otherwise Apple's server-backed
/// dictation is used (network access is covered by Full Access). Apple Speech
/// runs out of process, so the extension's own footprint stays within the
/// keyboard memory budget — no model weights are loaded here.
@MainActor
final class KeyboardDictationEngine: KeyboardDictationEngineProtocol {
    var onEvent: ((UUID, KeyboardDictationMachine.Event) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var interruptionObserver: NSObjectProtocol?
    private var finalizationTimeout: Task<Void, Never>?
    private var lastHypothesis = ""
    private var isStopping = false
    private var activeRunID: UUID?
    private var tapInstalled = false

    // MARK: - Preflight state used by the capture-path planner

    static func microphonePermission() -> KeyboardCapturePlanner.Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .denied
        }
    }

    static func speechRecognitionPermission() -> KeyboardCapturePlanner.Permission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .denied
        }
    }

    static func recognizerAvailable(localeIdentifier: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) != nil
    }

    // MARK: - Session control

    func start(runID: UUID, localeIdentifier: String) {
        guard activeRunID == nil else { return }
        activeRunID = runID
        isStopping = false
        lastHypothesis = ""
        Task { [weak self, runID] in
            await self?.requestPermissionsThenCapture(runID: runID, localeIdentifier: localeIdentifier)
        }
    }

    /// Ends audio input gracefully; the final transcript arrives as a
    /// `.finalized` event (with a timeout so the keyboard can never hang).
    func stop(runID: UUID) {
        guard activeRunID == runID, !isStopping else { return }
        isStopping = true
        stopAudioOnly()
        request?.endAudio()
        armFinalizationTimeout(runID: runID)
    }

    /// Tears everything down without delivering further events.
    func cancel(runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        finalizationTimeout?.cancel()
        finalizationTimeout = nil
        task?.cancel()
        teardown()
    }

    // MARK: - Startup

    private func requestPermissionsThenCapture(runID: UUID, localeIdentifier: String) async {
        guard activeRunID == runID else { return }
        guard await Self.ensureMicrophonePermission() else {
            fail(.microphoneUnavailable, runID: runID)
            return
        }
        guard activeRunID == runID else { return }
        guard await Self.ensureSpeechPermission() else {
            fail(.speechRecognitionUnavailable, runID: runID)
            return
        }
        guard activeRunID == runID else { return }
        beginCapture(runID: runID, localeIdentifier: localeIdentifier)
    }

    private static func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            // On-device verification required: iOS may decline to present
            // permission prompts from a keyboard extension. A refusal surfaces
            // as a normal failure and the keyboard falls back to handoff.
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    private static func ensureSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    private func beginCapture(runID: UUID, localeIdentifier: String) {
        guard activeRunID == runID else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            fail(.speechRecognitionUnavailable, runID: runID)
            return
        }
        self.recognizer = recognizer

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            fail(.microphoneUnavailable, runID: runID)
            return
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            fail(.microphoneUnavailable, runID: runID)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            fail(.microphoneUnavailable, runID: runID)
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self, runID] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                self?.handleRecognition(runID: runID, text: text, isFinal: isFinal, failed: failed)
            }
        }

        observeInterruptions(runID: runID)
        guard activeRunID == runID else { return }
        onEvent?(runID, .captureStarted)
    }

    // MARK: - Recognition results

    private func handleRecognition(runID: UUID, text: String?, isFinal: Bool, failed: Bool) {
        guard activeRunID == runID else { return }
        if let text, !text.isEmpty {
            lastHypothesis = text
        }
        if isFinal {
            deliverFinal(text ?? lastHypothesis, runID: runID)
            return
        }
        if failed {
            // Recognition errors also fire for end-of-audio silence. Deliver
            // the best hypothesis so far instead of dropping spoken words; a
            // failure with no words at all surfaces as an interruption.
            if isStopping || !lastHypothesis.isEmpty {
                deliverFinal(lastHypothesis, runID: runID)
            } else {
                fail(.audioInterrupted, runID: runID)
            }
            return
        }
        if let text, !text.isEmpty {
            onEvent?(runID, .hypothesis(text))
        }
    }

    private func deliverFinal(_ transcript: String, runID: UUID) {
        guard activeRunID == runID else { return }
        finalizationTimeout?.cancel()
        finalizationTimeout = nil
        activeRunID = nil
        teardown()
        onEvent?(runID, .finalized(transcript))
    }

    private func fail(_ failure: KeyboardDictationMachine.Failure, runID: UUID) {
        guard activeRunID == runID else { return }
        finalizationTimeout?.cancel()
        finalizationTimeout = nil
        activeRunID = nil
        teardown()
        onEvent?(runID, .captureFailed(failure))
    }

    private func armFinalizationTimeout(runID: UUID) {
        finalizationTimeout?.cancel()
        finalizationTimeout = Task { [weak self, runID] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard let self, self.activeRunID == runID, self.isStopping else { return }
            self.task?.cancel()
            self.deliverFinal(self.lastHypothesis, runID: runID)
        }
    }

    // MARK: - Teardown

    private func stopAudioOnly() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine.stop()
    }

    private func teardown() {
        stopAudioOnly()
        request = nil
        task = nil
        recognizer = nil
        isStopping = false
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeInterruptions(runID: UUID) {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self, runID] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard typeValue == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self, self.activeRunID == runID else { return }
                self.onEvent?(runID, .interrupted)
            }
        }
    }
}
