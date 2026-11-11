import Foundation
import SpeakCore
import SpeakDesktop

struct DesktopHostConnectionWarmCapture {
    let recordID: UUID
    let model: String
    let options: DesktopPostProcessing.Options
    var credentialsReady = false
}

extension DesktopHostController {
    /// Existing native device/session notifications revoke stale readiness;
    /// this never queries permission, opens audio or starts a request.
    package func connectionWarmEnvironmentChanged() {
        invalidateConnectionPreWarming(resetCapture: true)
    }

    /// Called only after the real capture's synchronous start acknowledgement.
    /// A configuration change during suspended startup invalidates that witness.
    func acknowledgeConnectionWarmCapture(
        generation: UUID, recordID: UUID, model: String, options: DesktopPostProcessing.Options
    ) {
        guard !closed, generation == connectionWarm.generation else { return }
        connectionWarm.capture = .init(recordID: recordID, model: model, options: options)
    }

    /// Reuses the real cleanup workflow's credential check; idle preparation
    /// never reads the vault or receives the key.
    func acknowledgeConnectionWarmCleanupCredential(recordID: UUID, model: String, available: Bool) {
        guard var captured = connectionWarm.capture, captured.recordID == recordID,
              captured.options.modelIdentifier == model else { return }
        captured.credentialsReady = available
        connectionWarm.capture = captured
    }

    func invalidateConnectionPreWarming(resetCapture: Bool) {
        connectionWarm.generation = UUID()
        connectionWarm.pending = false
        connectionWarm.task?.task.cancel()
        connectionWarm.tracker.invalidate()
        if resetCapture {
            connectionWarm.capture = nil
            refreshCapturePreparation()
            endShortcutPressMicrophone()
        }
    }

    func pauseConnectionPreWarming() {
        guard connectionWarm.task != nil else { return }
        invalidateConnectionPreWarming(resetCapture: false)
    }

    func beginConnectionWarmCredentialWork() {
        connectionWarm.credentialWork += 1
        invalidateConnectionPreWarming(resetCapture: true)
    }

    func endConnectionWarmCredentialWork() {
        connectionWarm.credentialWork -= 1
        invalidateConnectionPreWarming(resetCapture: true)
    }

    var connectionWarmEligible: Bool {
        guard isReady, !closed, !busy, activeOperations == 0, connectionWarm.credentialWork == 0,
              recording == nil, handsFreeRun == nil,
              ownedCaptureStartup == nil, ownedDictation == nil, ownedDictationAdmission == nil,
              microphoneWarning == nil, connectionWarm.approved,
              let capture = connectionWarm.capture,
              capture.credentialsReady,
              DesktopLiveTranscription.route(forID: capture.model) == nil,
              capture.options.mode == .remote, !capture.options.streamingEnabled,
              DesktopPostProcessing.mode(for: capture.options.modelIdentifier) == .remote,
              let configuration = settings.configuration,
              configuration.enabled(DesktopConnectionPreWarming.preferenceKey),
              configuration.text("speedMode") != SpeedModeID.livePolish.rawValue else { return false }
        return true
    }

    /// No timer or retry: only a real idle transition can admit one probe.
    func reconcileConnectionPreWarming() {
        guard connectionWarmEligible else { return }
        guard connectionWarm.task == nil else { connectionWarm.pending = true; return }
        guard let host = OpenRouterConnectionWarmer.origin.host,
              connectionWarm.tracker.hostNeedingWarmUp(using: .endpointProbe(host: host), now: Date()) != nil else {
            return
        }
        let id = UUID()
        let generation = connectionWarm.generation
        let effects = effects
        let task = Task { [weak self] in
            let succeeded: Bool
            do {
                try Task.checkCancellation()
                try await effects.warmPostProcessingConnection()
                try Task.checkCancellation()
                succeeded = true
            } catch {
                succeeded = false
            }
            await self?.finishConnectionPreWarming(id: id, generation: generation, host: host, succeeded: succeeded)
        }
        connectionWarm.task = (id, task)
    }

    private func finishConnectionPreWarming(id: UUID, generation: UUID, host: String, succeeded: Bool) {
        guard connectionWarm.task?.id == id else { return }
        connectionWarm.task = nil
        let pending = connectionWarm.pending
        connectionWarm.pending = false
        if generation == connectionWarm.generation, connectionWarmEligible {
            if succeeded { connectionWarm.tracker.markWarmed(host: host, at: Date()) } else {
                connectionWarm.tracker.markFailed(host: host)
                connectionWarm.capture = nil
                update("Connection preparation failed. Cleanup will connect normally; no idle retry was scheduled.")
            }
        }
        if pending { reconcileConnectionPreWarming() }
    }
}
