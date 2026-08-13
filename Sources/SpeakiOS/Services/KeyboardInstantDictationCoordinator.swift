#if os(iOS)
import AVFoundation
import Combine
import Foundation
import SpeakCore
import UIKit

// swiftlint:disable file_length

/// Owns the containing app's foreground-started Instant Dictation microphone
/// session. Once the user enables it, the session remains ready until they turn
/// it off, iOS interrupts it, or the app is terminated.
///
/// Idle buffers are discarded immediately. They are never persisted, sent to a
/// transcription provider, or placed in the App Group. Actual transcription
/// starts only after the keyboard creates a nonce-scoped handoff request.
@MainActor
// swiftlint:disable:next type_body_length
public final class KeyboardInstantDictationCoordinator: ObservableObject {
    public static let shared = KeyboardInstantDictationCoordinator()

    @Published public private(set) var session: KeyboardInstantDictationSession?
    @Published public private(set) var errorMessage: String?

    private let sessionStore = KeyboardInstantDictationStore.shared
    private let handoffStore = KeyboardHandoffStore.shared
    private let recordingService = TranscriptionRecordingService.shared
    private let readinessAudio = KeyboardReadinessAudioSession()

    private var signalObservation: KeyboardHandoffSignalObservation?
    private var partialTranscriptObservation: AnyCancellable?
    private var heartbeatTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var activeProfile: KeyboardDictationProfileOption?

    private init() {}

    public var isReady: Bool {
        session?.phase == .ready && sessionStore.activeSession(clearingStaleRecord: true) != nil
    }

    public var isEnabled: Bool {
        sessionStore.isEnabled
    }

    public var isRecording: Bool {
        session?.phase == .recording
    }

    public func activate() {
        ensureSignalObservation()
        // Keep the keyboard's quick-switch chips in sync with the app's spoken
        // language and post-processing preferences on every foreground
        // activation.
        KeyboardDictationPreferencesStore.shared.mirrorAppPreference(
            selectedIdentifier: AppSettings.shared.preferredLocaleIdentifier
        )
        AppSettings.shared.publishKeyboardProfileSelection()
        session = sessionStore.activeSession(clearingStaleRecord: true)
        guard sessionStore.isEnabled,
              UIApplication.shared.applicationState == .active,
              startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.startSession()
            self?.startTask = nil
        }
    }

    private func ensureSignalObservation() {
        if signalObservation == nil {
            signalObservation = KeyboardHandoffSignal.observeRequestChanges { [weak self] in
                Task { @MainActor in
                    self?.handleRequestChange()
                }
            }
        }
    }

    /// Enables Instant Dictation from the foreground. The first call is an
    /// explicit consent boundary; the preference then survives future app
    /// launches so readiness restarts automatically whenever the app opens.
    public func startSession() async {
        ensureSignalObservation()
        errorMessage = nil

        if readinessAudio.isRunning,
           let active = sessionStore.activeSession(clearingStaleRecord: true) {
            sessionStore.setEnabled(true)
            session = active
            return
        }

        guard UIApplication.shared.applicationState == .active else {
            errorMessage = "Open Just Speak once to reconnect Instant Dictation."
            return
        }
        guard !recordingService.isRunning else {
            errorMessage = "Finish the current recording before enabling Instant Dictation."
            return
        }

        let audioSessionManager = AudioSessionManager()
        var hasMicrophonePermission = audioSessionManager.hasMicrophonePermission()
        if !hasMicrophonePermission {
            hasMicrophonePermission = await audioSessionManager.requestMicrophonePermission()
        }
        guard hasMicrophonePermission else {
            errorMessage = "Microphone access is required for Instant Dictation."
            return
        }

        do {
            try readinessAudio.start()
            // `enabling: true` turns the preference on and creates the session
            // in one locked store transaction, so a concurrent disable can't
            // interleave between the two writes.
            guard let started = sessionStore.start(enabling: true) else {
                readinessAudio.stop(deactivateAudioSession: true)
                errorMessage = "Instant Dictation could not access the shared keyboard container."
                return
            }
            session = started
            startHeartbeat()
            handleRequestChange()
        } catch {
            readinessAudio.stop(deactivateAudioSession: true)
            sessionStore.end()
            session = nil
            errorMessage = "Instant Dictation could not start the microphone: \(error.localizedDescription)"
        }
    }

    public func endSession(disable: Bool = true) {
        startTask?.cancel()
        startTask = nil
        requestTask?.cancel()
        requestTask = nil
        partialTranscriptObservation = nil
        if recordingService.isRunning {
            recordingService.cancelRecording()
        }
        if let activeRequestID {
            _ = try? handoffStore.cancel(requestID: activeRequestID)
        }
        activeRequestID = nil
        activeProfile = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        readinessAudio.stop(deactivateAudioSession: true)
        sessionStore.end()
        if disable {
            sessionStore.setEnabled(false)
        }
        session = nil
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let updated = self.sessionStore.heartbeat() else {
                    self.errorMessage = "Instant Dictation disconnected because its session state was unavailable."
                    self.endSession(disable: false)
                    return
                }
                guard updated.phase == .recording || self.readinessAudio.isRunning else {
                    self.errorMessage = "Instant Dictation disconnected after an audio interruption."
                    self.endSession(disable: false)
                    return
                }
                self.session = updated
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func handleRequestChange() {
        guard requestTask == nil else { return }
        guard sessionStore.activeSession(clearingStaleRecord: true) != nil,
              let record = handoffStore.activeRecord() else { return }

        switch record.phase {
        case .requested:
            requestTask = Task { [weak self] in
                await self?.beginRecording(for: record)
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

    private func beginRecording(for record: KeyboardHandoffRecord) async {
        let requestID = record.requestID
        guard activeRequestID == nil, !recordingService.isRunning else {
            _ = try? handoffStore.fail(requestID: requestID, code: .recordingUnavailable)
            return
        }
        await AppSettings.shared.ensureKeysLoaded()
        guard let profile = record.profile, profileIsAvailable(profile) else {
            _ = try? handoffStore.fail(requestID: requestID, code: .profileUnavailable)
            return
        }

        // Mark the audio mode transition before stopping the readiness engine.
        // Provider setup can take longer than one heartbeat; without this the
        // liveness loop would mistake a healthy engine swap for interruption.
        activeRequestID = requestID
        activeProfile = profile
        session = sessionStore.heartbeat(phase: .recording)
        readinessAudio.stop(deactivateAudioSession: false)
        do {
            try await recordingService.startRecording(
                retainBatchRecording: false,
                sharesLiveTranscript: false,
                requiresLiveActivity: false,
                keyboardProfile: profile
            )
            try handoffStore.markRecording(requestID: requestID)
            observePartialTranscript(for: requestID)
        } catch {
            partialTranscriptObservation = nil
            recordingService.cancelRecording()
            _ = try? handoffStore.fail(requestID: requestID, code: .recordingUnavailable)
            activeRequestID = nil
            activeProfile = nil
            await resumeReadinessAfterRequest()
        }
    }

    private func finishRecording(for requestID: UUID) async {
        guard activeRequestID == requestID, recordingService.isRunning else {
            _ = try? handoffStore.fail(requestID: requestID, code: .invalidRequest)
            return
        }

        partialTranscriptObservation = nil
        _ = try? handoffStore.updateInterim(
            requestID: requestID,
            transcript: recordingService.partialText
        )
        do {
            try handoffStore.markTranscribing(requestID: requestID)
        } catch {
            recordingService.cancelRecording()
            _ = try? handoffStore.fail(requestID: requestID, code: .invalidRequest)
            activeRequestID = nil
            activeProfile = nil
            await resumeReadinessAfterRequest()
            return
        }

        let profile = activeProfile
        let result = await recordingService.stopRecording(
            destination: .historyOnly,
            saveToHistory: false,
            primedActivityMessage: "Keyboard ready"
        )
        activeRequestID = nil
        activeProfile = nil
        var transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let profile, profile.polishes, !transcript.isEmpty {
            do {
                transcript = try await polish(transcript, with: profile)
            } catch {
                saveToHistory(result.text, result: result)
                _ = try? handoffStore.fail(requestID: requestID, code: .profileUnavailable)
                await resumeReadinessAfterRequest()
                return
            }
        }
        if transcript.isEmpty {
            _ = try? handoffStore.fail(requestID: requestID, code: .noSpeech)
        } else {
            saveToHistory(transcript, result: result)
            _ = try? handoffStore.complete(requestID: requestID, transcript: transcript)
        }
        await resumeReadinessAfterRequest()
    }

    private func cancelRecording(for requestID: UUID) {
        guard activeRequestID == requestID else { return }
        partialTranscriptObservation = nil
        if recordingService.isRunning {
            recordingService.cancelRecording()
        }
        activeRequestID = nil
        activeProfile = nil
        Task {
            await resumeReadinessAfterRequest()
        }
    }

    private func resumeReadinessAfterRequest() async {
        guard sessionStore.isEnabled else {
            endSession(disable: true)
            return
        }
        do {
            try readinessAudio.start()
            session = sessionStore.heartbeat(phase: .ready)
        } catch {
            errorMessage = "Instant Dictation disconnected because the microphone could not be reactivated."
            endSession(disable: false)
        }
    }

    private func observePartialTranscript(for requestID: UUID) {
        partialTranscriptObservation = recordingService.$partialText
            .removeDuplicates()
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] text in
                guard self?.activeRequestID == requestID else { return }
                _ = try? self?.handoffStore.updateInterim(
                    requestID: requestID,
                    transcript: text
                )
            }
    }

    private func profileIsAvailable(_ profile: KeyboardDictationProfileOption) -> Bool {
        let settings = AppSettings.shared
        if profile.transcriptionMode == .streaming {
            guard let route = LiveTranscriptionRouting.route(for: profile.transcriptionModelIdentifier),
                  route.isSupportedOnIOS else {
                return false
            }
            if route.apiKeyIdentifier != nil,
               settings.liveAPIKey(for: route).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        if profile.transcriptionMode == .batch {
            guard AppSettings.supportedBatchModels.contains(where: {
                $0.id == profile.transcriptionModelIdentifier
            }) else {
                return false
            }
            if profile.transcriptionModelIdentifier != AppleLocalModels.speechTranscriberModelID,
               settings.batchAPIKey(for: profile.transcriptionModelIdentifier)
                   .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        guard profile.polishes, let postProcessingModel = profile.postProcessingModelIdentifier else { return true }
        guard AppSettings.postProcessingModels.contains(where: {
            $0.id == postProcessingModel
        }) else {
            return false
        }
        if postProcessingModel == AppleLocalModels.foundationModelID {
            return AppleFoundationModelPolisher.isAvailable
        }
        return settings.hasOpenRouterKey
    }

    private func polish(_ transcript: String, with profile: KeyboardDictationProfileOption) async throws -> String {
        guard let model = profile.postProcessingModelIdentifier else { return transcript }
        let response = try await iOSPostProcessingManager.shared.polish(
            text: transcript,
            model: model,
            apiKey: AppSettings.shared.openRouterAPIKey
        )
        let polished = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else { throw PostProcessingError.emptyResult }
        return polished
    }

    private func saveToHistory(_ transcript: String, result: TranscriptionResult) {
        iOSHistoryManager.shared.recordTranscription(
            text: transcript,
            model: result.modelIdentifier,
            duration: result.duration
        )
    }
}

/// Holds an explicit foreground-started recording session open while discarding
/// idle buffers. This keeps iOS from suspending the containing app while
/// Instant Dictation is enabled, without sending or saving idle audio.
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
            stop(deactivateAudioSession: true)
            throw KeyboardReadinessAudioError.noInput
        }
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 4_096, format: format) { _, _ in
                // Deliberately discard idle audio. No persistence or network IO.
            }
            tapInstalled = true
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop(deactivateAudioSession: true)
            throw error
        }
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
