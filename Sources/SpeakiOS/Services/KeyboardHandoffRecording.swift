#if os(iOS)
import Combine
import Foundation
import SpeakCore
import UIKit

/// What a keyboard hand-off recording needs from the Instant Dictation
/// readiness session that holds the microphone between dictations.
@MainActor
protocol KeyboardHandoffReadinessHost: AnyObject {
    var isReadinessRunning: Bool { get }
    /// Stops the readiness engine but leaves the audio session active for the dictation.
    func pauseReadinessForRecording()
    /// Records that the readiness session is now recording.
    func handoffDidBeginRecording()
    func resumeReadinessAfterRequest() async
}

/// The containing app's side of one keyboard hand-off at a time.
///
/// It claims the nonce-scoped request, starts the dictation, mirrors its
/// interim text into the App Group, then finishes, polishes, saves or cancels
/// it. Every completion re-checks the active request and its hand-off phase,
/// so a cancelled or replaced request never receives another's result.
@MainActor
final class KeyboardHandoffRecording {
    weak var host: KeyboardHandoffReadinessHost?
    private let handoffStore: KeyboardHandoffStore
    private lazy var recordingService = TranscriptionRecordingService.shared
    private(set) var activeRequestID: UUID?
    private var activeProfile: KeyboardDictationProfileOption?
    private var finalisingRequestIDs: Set<UUID> = []
    private var partialTranscriptObservation: AnyCancellable?

    /// Injectable effects keep hand-off ordering tests independent of microphones and providers.
    struct FinalisationOperations {
        var isRunning: @MainActor () -> Bool
        var partialText: @MainActor () -> String
        var stop: @MainActor () async -> TranscriptionResult
        var cancel: @MainActor () -> Void
        var polish: @MainActor (String, KeyboardDictationProfileOption) async throws -> String
        var save: @MainActor (String, TranscriptionResult) async -> Void
        var resumeReadiness: @MainActor () async -> Void
    }

    lazy var finalisation = FinalisationOperations(
        isRunning: { [unowned self] in self.recordingService.isRunning },
        partialText: { [unowned self] in self.recordingService.partialText },
        stop: { [unowned self] in
            await self.recordingService.stopRecording(
                selection: CaptureDestinationSelection(destination: .historyOnly, origin: .keyboardProfile),
                saveToHistory: false,
                primedActivityMessage: "Keyboard ready",
                // The keyboard's own result travels the nonce-scoped hand-off
                // record; publishing a second copy as a pickup offer would
                // insert it twice.
                keyboardDeliverySource: nil
            )
        },
        cancel: { [unowned self] in self.recordingService.cancelRecording() },
        polish: { try await KeyboardHandoffProfileSupport.polish($0, with: $1) },
        save: { await KeyboardHandoffProfileSupport.saveToHistory($0, result: $1) },
        resumeReadiness: { [unowned self] in await self.host?.resumeReadinessAfterRequest() }
    )

    init(handoffStore: KeyboardHandoffStore) {
        self.handoffStore = handoffStore
    }

    func claimRecording(for record: KeyboardHandoffRecord) {
        activeRequestID = record.requestID
        activeProfile = record.profile
    }

    /// Abandons the active request when readiness ends: the dictation is
    /// cancelled and the keyboard sees its request cancelled.
    func abandon() {
        partialTranscriptObservation = nil
        if recordingService.isRunning {
            recordingService.cancelRecording()
        }
        if let activeRequestID {
            _ = try? handoffStore.cancel(requestID: activeRequestID)
        }
        clearActiveRequest()
    }

    private func clearActiveRequest() {
        activeRequestID = nil
        activeProfile = nil
    }

    func beginRecording(for record: KeyboardHandoffRecord, requestedAt: Date) async {
        let requestID = record.requestID
        guard activeRequestID == nil, !recordingService.isRunning else {
            failStart(requestID: requestID, stage: .busy)
            return
        }
        let settings = AppSettings.shared
        await settings.ensureKeysLoaded()
        if let profile = record.profile {
            do {
                try settings.requireAvailableCredentials(
                    for: profile.transcriptionModelIdentifier,
                    purpose: profile.transcriptionMode == .batch ? .batchTranscription : .liveTranscription
                )
            } catch {
                failStart(requestID: requestID, stage: .credentials, error: error)
                return
            }
        }
        guard let profile = record.profile, KeyboardHandoffProfileSupport.isAvailable(profile) else {
            failStart(requestID: requestID, stage: .profile)
            return
        }

        // Mark the audio mode transition before stopping the readiness engine.
        // Provider setup can take longer than one heartbeat; without this the
        // liveness loop would mistake a healthy engine swap for interruption.
        claimRecording(for: record)
        host?.handoffDidBeginRecording()
        holdReadinessThroughRecordingIfNeeded()
        do {
            try await recordingService.startRecording(
                retainBatchRecording: false,
                sharesLiveTranscript: false,
                requiresLiveActivity: false,
                keyboardProfile: profile,
                destination: .historyOnly,
                entry: StartupEntry(origin: .keyboardHandoff, observedAt: requestedAt),
                onCaptureDisruption: { [weak self] in
                    await self?.finishRecording(for: requestID)
                }
            )
            try handoffStore.markRecording(requestID: requestID)
            observePartialTranscript(for: requestID)
        } catch {
            partialTranscriptObservation = nil
            recordingService.cancelRecording()
            failStart(requestID: requestID, stage: .recording, error: error)
            clearActiveRequest()
            await host?.resumeReadinessAfterRequest()
        }
    }

    /// Hands the microphone from readiness to the dictation.
    ///
    /// In the background the readiness engine keeps running and the session
    /// stays active, because iOS lets a background app continue recording but
    /// not start it (issue #1469). In the foreground it is stopped as before.
    private func holdReadinessThroughRecordingIfNeeded() {
        let inForeground = UIApplication.shared.applicationState != .background
        let keepsRunning = KeyboardHandoffStartDiagnosis.keepsReadinessRunningDuringRecording(
            applicationIsInForeground: inForeground,
            readinessIsRunning: host?.isReadinessRunning ?? false
        )
        let decision = "appForeground=\(inForeground) keepsReadiness=\(keepsRunning)"
        SpeakLogger.transcription.info("Keyboard hand-off start: \(decision, privacy: .public)")
        if keepsRunning {
            AudioSessionManager.activeSessionHold = { [weak host] in
                host?.isReadinessRunning ?? false
            }
        } else {
            AudioSessionManager.activeSessionHold = nil
            host?.pauseReadinessForRecording()
        }
    }

    /// Fails a hand-off start with the code that says what actually went
    /// wrong, and logs a privacy-safe line naming the stage, app state and
    /// audio error so a device report is diagnosable (issue #1469).
    private func failStart(
        requestID: UUID,
        stage: KeyboardHandoffStartDiagnosis.Stage,
        error: Error? = nil
    ) {
        let cause = error.map(Self.audioCause(of:))
        let inForeground = UIApplication.shared.applicationState != .background
        let summary = KeyboardHandoffStartDiagnosis.diagnosticSummary(
            stage: stage, error: cause, applicationIsInForeground: inForeground
        )
        SpeakLogger.transcription.error("Keyboard hand-off start failed: \(summary, privacy: .public)")
        _ = try? handoffStore.fail(
            requestID: requestID,
            code: KeyboardHandoffStartDiagnosis.failureCode(
                stage: stage, error: cause, applicationIsInForeground: inForeground
            )
        )
    }

    /// The `AVAudioSession` error behind a wrapped transcriber start failure.
    static func audioCause(of error: Error) -> Error {
        var cause = error
        if case let iOSTranscriptionError.audioSessionFailed(inner) = cause {
            cause = inner
        }
        if let configuration = cause as? AudioSessionConfigurationError {
            return configuration.underlying
        }
        return cause
    }

    func finishRecording(for requestID: UUID) async {
        // Claim before the running guard: stop() clears isRunning while its provider drains.
        // A queued keyboard Finish must preserve the disruption's outcome, never write invalidRequest.
        guard finalisingRequestIDs.insert(requestID).inserted else { return }
        defer { finalisingRequestIDs.remove(requestID) }
        guard activeRequestID == requestID, finalisation.isRunning() else {
            _ = try? handoffStore.fail(requestID: requestID, code: .invalidRequest)
            return
        }

        partialTranscriptObservation = nil
        _ = try? handoffStore.updateInterim(requestID: requestID, transcript: finalisation.partialText())
        do {
            try handoffStore.markTranscribing(requestID: requestID)
        } catch {
            finalisation.cancel()
            _ = try? handoffStore.fail(requestID: requestID, code: .invalidRequest)
            await releaseRecording(for: requestID)
            return
        }

        let profile = activeProfile
        let result = await finalisation.stop()
        guard canComplete(requestID) else {
            await releaseRecording(for: requestID)
            return
        }
        var transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let profile, profile.polishes, !transcript.isEmpty {
            do {
                transcript = try await finalisation.polish(transcript, profile)
            } catch {
                if canComplete(requestID) {
                    await saveAndComplete(result.text, result: result, requestID: requestID, failedPolish: true)
                }
                await releaseRecording(for: requestID)
                return
            }
        }
        guard canComplete(requestID) else {
            await releaseRecording(for: requestID)
            return
        }
        if transcript.isEmpty {
            _ = try? handoffStore.fail(requestID: requestID, code: .noSpeech)
        } else {
            await saveAndComplete(transcript, result: result, requestID: requestID, failedPolish: false)
        }
        await releaseRecording(for: requestID)
    }

    private func saveAndComplete(
        _ transcript: String, result: TranscriptionResult, requestID: UUID, failedPolish: Bool
    ) async {
        await finalisation.save(transcript, result)
        // Persisting suspends; a cancelled/replaced request must not receive this result.
        guard canComplete(requestID) else { return }
        if failedPolish {
            _ = try? handoffStore.fail(requestID: requestID, code: .profileUnavailable)
        } else {
            _ = try? handoffStore.complete(requestID: requestID, transcript: transcript)
        }
    }

    private func canComplete(_ requestID: UUID) -> Bool {
        !Task.isCancelled && activeRequestID == requestID
            && handoffStore.record(matching: requestID)?.phase == .transcribing
    }

    private func releaseRecording(for requestID: UUID) async {
        guard activeRequestID == requestID else { return }
        clearActiveRequest()
        await finalisation.resumeReadiness()
    }

    func cancelRecording(for requestID: UUID) {
        guard activeRequestID == requestID else { return }
        partialTranscriptObservation = nil
        if finalisation.isRunning() {
            finalisation.cancel()
        }
        clearActiveRequest()
        Task {
            await finalisation.resumeReadiness()
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
}
#endif
