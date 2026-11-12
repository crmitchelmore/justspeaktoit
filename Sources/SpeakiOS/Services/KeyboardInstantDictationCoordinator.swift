#if os(iOS)
import Combine
import Foundation
import SpeakCore
import UIKit

/// Owns the containing app's foreground-started Instant Dictation microphone
/// session: its consent, its liveness heartbeat and bounds, and routing each
/// keyboard request to ``KeyboardHandoffRecording``. Once the user enables
/// it, the session remains ready until they turn it off, iOS interrupts it,
/// or the app is terminated.
///
/// Idle buffers are discarded immediately. They are never persisted, sent to a
/// transcription provider, or placed in the App Group. Actual transcription
/// starts only after the keyboard creates a nonce-scoped handoff request.
@MainActor
public final class KeyboardInstantDictationCoordinator: ObservableObject {
    public static let shared = KeyboardInstantDictationCoordinator()

    @Published public private(set) var session: KeyboardInstantDictationSession?
    @Published public private(set) var errorMessage: String?

    private let sessionStore: KeyboardInstantDictationStore
    private let handoffStore: KeyboardHandoffStore
    private lazy var recordingService = TranscriptionRecordingService.shared
    private lazy var readinessAudio = KeyboardReadinessAudioSession()
    /// The keyboard hand-off currently being dictated, if any.
    let handoff: KeyboardHandoffRecording

    private var signalObservation: KeyboardHandoffSignalObservation?
    private var heartbeatTask: Task<Void, Never>?
    private(set) var requestTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    /// The bounds this readiness session runs to (issue #995). Every rule —
    /// the window, the resume back-off and the attempt budget that stops an
    /// auto-resume looping — lives in SpeakCore and is proved on the host.
    private var bounds = InstantDictationReadinessMonitor()
    /// When the readiness session the bounds belong to started. Cleared with
    /// the session, so a retired session's tick can never act.
    private var boundsStartedAt: Date?

    /// Readiness keeps the microphone open for up to four hours and restarts
    /// whenever the app opens, which is the iPhone's usual "why is the
    /// microphone on?" (issue #1471). Status names it and turns it off.
    private var readinessHold: SystemResourceToken?

    private func holdReadinessMicrophone() {
        guard readinessHold == nil else { return }
        readinessHold = SystemResourceRegistry.shared.acquire(
            kind: .microphone, title: "Instant Dictation",
            reason: "Keeps the microphone ready for the Just Speak keyboard. Idle audio is discarded, "
                + "never saved or sent. Ends after 4 hours; restarts when you open the app.",
            owner: "KeyboardInstantDictationCoordinator", releaseTitle: "Turn off",
            release: { [weak self] in await MainActor.run { self?.endSession(disable: true) } }
        )
    }

    private convenience init() {
        self.init(sessionStore: .shared, handoffStore: .shared)
    }

    init(sessionStore: KeyboardInstantDictationStore, handoffStore: KeyboardHandoffStore) {
        self.sessionStore = sessionStore
        self.handoffStore = handoffStore
        handoff = KeyboardHandoffRecording(handoffStore: handoffStore)
        handoff.host = self
    }

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
            // A process that was relaunched into a live session still needs
            // the window measured from when that session actually started.
            if boundsStartedAt == nil {
                armReadinessBounds(startedAt: active.startedAt)
                startHeartbeat()
            }
            holdReadinessMicrophone()
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
            holdReadinessMicrophone()
            armReadinessBounds(startedAt: started.startedAt)
            startHeartbeat()
            handleRequestChange()
        } catch {
            readinessAudio.stop(deactivateAudioSession: true)
            sessionStore.end()
            session = nil
            errorMessage = "Instant Dictation could not start the microphone: \(error.localizedDescription)"
        }
    }

    /// Finishes the keyboard's in-flight dictation on behalf of a hardware
    /// trigger (issue #1002), so a physical press lands the transcript in the
    /// field the keyboard opened it for instead of colliding with it.
    ///
    /// Nothing about the destination changes: the result travels the existing
    /// nonce-scoped hand-off, which refuses to insert unless the keyboard is
    /// still in the same document.
    @discardableResult
    public func finishKeyboardSession(requestID: UUID) -> Bool {
        guard handoff.activeRequestID == requestID || handoffStore.activeRecord()?.requestID == requestID else {
            return false
        }
        // `requestFinish` is idempotent, so a second press while the app is
        // already finalising is a safe no-op rather than a second stop.
        guard (try? handoffStore.requestFinish(requestID: requestID)) != nil else { return false }
        KeyboardHandoffSignal.postRequestChanged()
        handleRequestChange()
        return true
    }

    public func endSession(disable: Bool = true) {
        startTask?.cancel()
        startTask = nil
        requestTask?.cancel()
        requestTask = nil
        handoff.abandon()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        readinessAudio.stop(deactivateAudioSession: true)
        sessionStore.end()
        if disable {
            sessionStore.setEnabled(false)
        }
        bounds.retire()
        boundsStartedAt = nil
        session = nil
        readinessHold?.end()
        readinessHold = nil
    }

    private func armReadinessBounds(startedAt: Date) {
        bounds = InstantDictationReadinessMonitor()
        boundsStartedAt = startedAt
        sessionStore.recordEndReason(nil)
    }

    /// The liveness loop, and the only place readiness heals or expires.
    ///
    /// It was already ticking once a second and already noticing that the
    /// engine had died; what it did about it was give up. Now the same tick
    /// feeds `InstantDictationReadinessMonitor`, which decides whether to try
    /// again, how long to wait first, and when to stop trying (issue #995).
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let updated = self.sessionStore.heartbeat() else {
                    self.finishReadiness(.storeUnavailable)
                    return
                }
                self.session = updated
                if await self.applyReadinessBounds(phase: updated.phase) { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// - Returns: `true` when readiness ended and the loop must stop.
    private func applyReadinessBounds(
        phase: KeyboardInstantDictationSession.Phase
    ) async -> Bool {
        guard let startedAt = boundsStartedAt else { return false }
        let health: InstantDictationReadinessHealth
        if phase == .recording {
            // A dictation owns the microphone. The readiness engine is stopped
            // on purpose during one, so this is health, not failure — and the
            // window never expires a session mid-dictation.
            health = .recording
        } else {
            health = readinessAudio.isRunning ? .running : .stopped
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        switch bounds.observe(health, atSeconds: elapsed) {
        case .idle:
            return false
        case .end(let reason):
            finishReadiness(reason)
            return true
        case .resume(let delay, let attempt):
            await resumeReadiness(afterSeconds: delay, attempt: attempt, startedAt: startedAt)
            return false
        }
    }

    /// Tries to restart the readiness engine after iOS took it away.
    ///
    /// The attempt is reported back to the monitor either way. A success does
    /// not refund the attempt — only two unbroken minutes of health does — so a
    /// session that dies every few seconds runs out of attempts rather than
    /// resuming forever.
    private func resumeReadiness(
        afterSeconds delay: TimeInterval,
        attempt: Int,
        startedAt: Date
    ) async {
        SpeakLogger.transcription.info(
            "Instant Dictation readiness: resume attempt \(attempt, privacy: .public)"
        )
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, boundsStartedAt == startedAt else { return }
        // A dictation that began while this attempt was waiting owns the
        // microphone now; taking it back would end their recording. The
        // restart therefore never ran, so it must not be charged against the
        // budget: normal handoffs would otherwise exhaust three attempts
        // without readiness ever having failed to restart, and end the session.
        guard handoff.activeRequestID == nil, !recordingService.isRunning else {
            bounds.refundUnattemptedResume()
            return
        }
        var succeeded = true
        do {
            try readinessAudio.start()
            session = sessionStore.heartbeat(phase: .ready)
        } catch {
            succeeded = false
        }
        bounds.noteResume(
            succeeded: succeeded,
            atSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    /// Ends readiness for a stated reason, leaving the user's preference on.
    ///
    /// The reason goes into the App Group as well as the app's own error
    /// message: the keyboard is a separate process and never sees the latter,
    /// so without the record it can only offer a generic reconnect prompt.
    private func finishReadiness(_ reason: InstantDictationReadinessEndReason) {
        errorMessage = reason.readinessMessage
        SpeakLogger.transcription.info(
            "Instant Dictation readiness ended: \(reason.rawValue, privacy: .public)"
        )
        endSession(disable: false)
        sessionStore.recordEndReason(reason)
    }

    func handleRequestChange() {
        guard requestTask == nil else { return }
        guard sessionStore.activeSession(clearingStaleRecord: true) != nil,
              let record = handoffStore.activeRecord() else { return }

        switch record.phase {
        case .requested:
            // The containing app begins handling the request here — before
            // credential loading and before readiness teardown — so this is
            // the earliest app-code entry the keyboard path can observe
            // (issue #972).
            let requestedAt = Date()
            requestTask = Task { [weak self] in
                await self?.handoff.beginRecording(for: record, requestedAt: requestedAt)
                self?.requestTask = nil
                self?.handleRequestChange()
            }
        case .finishRequested:
            requestTask = Task { [weak self] in
                await self?.handoff.finishRecording(for: record.requestID)
                self?.requestTask = nil
                self?.handleRequestChange()
            }
        case .cancelled:
            handoff.cancelRecording(for: record.requestID)
        case .recording, .transcribing, .completed, .failed:
            break
        }
    }
}

extension KeyboardInstantDictationCoordinator: KeyboardHandoffReadinessHost {
    var isReadinessRunning: Bool { readinessAudio.isRunning }

    func pauseReadinessForRecording() {
        readinessAudio.stop(deactivateAudioSession: false)
    }

    func lendReadinessEngine() -> LiveCaptureInput.EngineLease? {
        readinessAudio.lendRunningEngine()
    }

    func handoffDidBeginRecording() {
        session = sessionStore.heartbeat(phase: .recording)
    }

    func resumeReadinessAfterRequest() async {
        LiveCaptureInput.engineLender = nil
        guard sessionStore.isEnabled else {
            endSession(disable: true)
            return
        }
        do {
            try readinessAudio.start()
            session = sessionStore.heartbeat(phase: .ready)
        } catch {
            // The same bounded outcome the liveness loop reaches, so a
            // microphone that cannot be taken back after a dictation is
            // reported the same way whichever path noticed it.
            finishReadiness(.audioUnavailable)
        }
    }
}
#endif
