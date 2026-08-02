#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import UIKit

/// Owns the containing app's foreground-started, time-limited microphone
/// session that makes keyboard-only start/stop commands possible while the app
/// remains alive in the background.
///
/// Idle buffers are discarded immediately. They are never persisted, sent to a
/// transcription provider, or placed in the App Group. Actual transcription
/// starts only after the keyboard creates a nonce-scoped handoff request.
@MainActor
public final class KeyboardQuickDictationCoordinator: ObservableObject {
    public static let shared = KeyboardQuickDictationCoordinator()

    @Published public private(set) var session: KeyboardQuickDictationSession?
    @Published public private(set) var errorMessage: String?

    private let sessionStore = KeyboardQuickDictationStore.shared
    private let handoffStore = KeyboardHandoffStore.shared
    private let recordingService = TranscriptionRecordingService.shared
    private let readinessAudio = KeyboardReadinessAudioSession()
    private let activityManager = TranscriptionActivityManager.shared

    private var signalObservation: KeyboardHandoffSignalObservation?
    private var heartbeatTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var activeRequestID: UUID?

    private init() {}

    public var isReady: Bool {
        session?.phase == .ready && sessionStore.activeSession() != nil
    }

    public var isRecording: Bool {
        session?.phase == .recording
    }

    public func activate() {
        guard signalObservation == nil else { return }
        signalObservation = KeyboardHandoffSignal.observeRequestChanges { [weak self] in
            Task { @MainActor in
                self?.handleRequestChange()
            }
        }
        session = sessionStore.activeSession()
    }

    /// Starts a bounded session only from the foreground, after an explicit
    /// user action. This is the supported boundary: a keyboard extension cannot
    /// cold-start microphone capture after iOS has suspended the app.
    public func startSession(duration: TimeInterval = KeyboardQuickDictationStore.defaultDuration) async {
        activate()
        errorMessage = nil

        guard UIApplication.shared.applicationState == .active else {
            errorMessage = "Open Just Speak to start Quick Dictation."
            return
        }
        guard !recordingService.isRunning else {
            errorMessage = "Finish the current recording before starting Quick Dictation."
            return
        }

        let audioSessionManager = AudioSessionManager()
        var hasMicrophonePermission = audioSessionManager.hasMicrophonePermission()
        if !hasMicrophonePermission {
            hasMicrophonePermission = await audioSessionManager.requestMicrophonePermission()
        }
        guard hasMicrophonePermission else {
            errorMessage = "Microphone access is required for Quick Dictation."
            return
        }

        do {
            try readinessAudio.start()
            guard let started = sessionStore.start(duration: duration) else {
                readinessAudio.stop(deactivateAudioSession: true)
                errorMessage = "Quick Dictation could not access the shared keyboard container."
                return
            }
            session = started
            _ = activityManager.startActivity(provider: "Keyboard Quick Dictation")
            startHeartbeat()
            handleRequestChange()
        } catch {
            readinessAudio.stop(deactivateAudioSession: true)
            sessionStore.end()
            session = nil
            errorMessage = "Quick Dictation could not start the microphone: \(error.localizedDescription)"
        }
    }

    public func endSession() {
        requestTask?.cancel()
        requestTask = nil
        if recordingService.isRunning {
            recordingService.cancelRecording()
        }
        if let activeRequestID {
            _ = try? handoffStore.cancel(requestID: activeRequestID)
        }
        activeRequestID = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        readinessAudio.stop(deactivateAudioSession: true)
        sessionStore.end()
        session = nil
        activityManager.endActivity()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let updated = self.sessionStore.heartbeat() else {
                    if !self.recordingService.isRunning {
                        self.endSession()
                    }
                    return
                }
                guard updated.phase == .recording || self.readinessAudio.isRunning else {
                    self.errorMessage = "Quick Dictation ended after an audio interruption."
                    self.endSession()
                    return
                }
                self.session = updated
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func handleRequestChange() {
        guard requestTask == nil else { return }
        guard sessionStore.activeSession() != nil,
              let record = handoffStore.activeRecord() else { return }

        switch record.phase {
        case .requested:
            requestTask = Task { [weak self] in
                await self?.beginRecording(for: record.requestID)
                self?.requestTask = nil
                self?.handleRequestChange()
            }
        case .finishRequested:
            requestTask = Task { [weak self] in
                await self?.finishRecording(for: record.requestID)
                self?.requestTask = nil
                self?.handleRequestChange()
            }
        case .cancelled:
            cancelRecording(for: record.requestID)
        case .recording, .transcribing, .completed, .failed:
            break
        }
    }

    private func beginRecording(for requestID: UUID) async {
        guard activeRequestID == nil, !recordingService.isRunning else {
            _ = try? handoffStore.fail(requestID: requestID, code: .recordingUnavailable)
            return
        }

        readinessAudio.stop(deactivateAudioSession: false)
        do {
            try await recordingService.startRecording(
                retainBatchRecording: false,
                sharesLiveTranscript: false
            )
            try handoffStore.markRecording(requestID: requestID)
            activeRequestID = requestID
            session = sessionStore.heartbeat(phase: .recording)
        } catch {
            recordingService.cancelRecording()
            _ = try? handoffStore.fail(requestID: requestID, code: .recordingUnavailable)
            await resumeReadinessAfterRequest()
        }
    }

    private func finishRecording(for requestID: UUID) async {
        guard activeRequestID == requestID, recordingService.isRunning else {
            _ = try? handoffStore.fail(requestID: requestID, code: .invalidRequest)
            return
        }

        do {
            try handoffStore.markTranscribing(requestID: requestID)
        } catch {
            recordingService.cancelRecording()
            _ = try? handoffStore.fail(requestID: requestID, code: .invalidRequest)
            activeRequestID = nil
            await resumeReadinessAfterRequest()
            return
        }

        let result = await recordingService.stopRecording(
            destination: .historyOnly,
            saveToHistory: true,
            primedActivityMessage: "Keyboard ready"
        )
        activeRequestID = nil
        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty {
            _ = try? handoffStore.fail(requestID: requestID, code: .noSpeech)
        } else {
            _ = try? handoffStore.complete(requestID: requestID, transcript: transcript)
        }
        await resumeReadinessAfterRequest()
    }

    private func cancelRecording(for requestID: UUID) {
        guard activeRequestID == requestID else { return }
        if recordingService.isRunning {
            recordingService.cancelRecording()
        }
        activeRequestID = nil
        Task {
            await resumeReadinessAfterRequest()
        }
    }

    private func resumeReadinessAfterRequest() async {
        guard let current = sessionStore.activeSession(), current.expiresAt > Date() else {
            endSession()
            return
        }
        do {
            try readinessAudio.start()
            session = sessionStore.heartbeat(phase: .ready)
            _ = activityManager.startActivity(provider: "Keyboard Quick Dictation")
        } catch {
            errorMessage = "Quick Dictation ended because the microphone could not be reactivated."
            endSession()
        }
    }
}

/// Holds an explicit foreground-started recording session open while discarding
/// idle buffers. This keeps iOS from suspending the containing app during the
/// user's short Quick Dictation window without sending or saving idle audio.
@MainActor
private final class KeyboardReadinessAudioSession {
    private let engine = AVAudioEngine()
    private var tapInstalled = false

    var isRunning: Bool {
        engine.isRunning
    }

    func start() throws {
        guard !engine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .allowBluetoothHFP]
        )
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw KeyboardReadinessAudioError.noInput
        }
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 4_096, format: format) { _, _ in
                // Deliberately discard idle audio. No persistence or network IO.
            }
            tapInstalled = true
        }
        engine.prepare()
        try engine.start()
    }

    func stop(deactivateAudioSession: Bool) {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

private enum KeyboardReadinessAudioError: LocalizedError {
    case noInput

    var errorDescription: String? {
        "No microphone input is available."
    }
}
#endif
