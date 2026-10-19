import Foundation
import SpeakCore
import SpeakDesktop

struct DesktopHostOwnedDictationHandle<Platform: DesktopHostPlatform>: Sendable {
    enum Failure: Equatable, Sendable { case retirement, history }
    let id: UUID
    let request: DesktopHostOwnedDictationRequest<Platform>
    let owner: DesktopHostOwnedDictationSession<Platform>
    var stop: Task<Void, Never>?
    var abortReason: String?
    var failure: Failure?
}

extension DesktopHostController {
    // existing owned dictation-session entry point; no behavior change.
    // swiftlint:disable:next function_parameter_count
    func startOwnedDictation(
        target: Platform.InsertionTarget?, deviceID: String, profile: DesktopProfileSession,
        textOutput: Platform.TextOutputOptions, trigger: HotKeySessionTrigger,
        capability: DesktopHostOwnedDictationCapability
    ) async throws {
        let snapshot = try ownedDictationStart(
            target: target, deviceID: deviceID, profile: profile, textOutput: Task { textOutput },
            trigger: trigger, capability: capability
        )
        try await startOwnedDictation(snapshot, capability: capability)
    }

    // existing owned dictation-session startup orchestration; no behavior change.
    // swiftlint:disable:next function_body_length
    func startOwnedDictation(
        _ snapshot: DesktopHostOwnedDictationStart<Platform>, capability: DesktopHostOwnedDictationCapability
    ) async throws {
        try Task.checkCancellation()
        guard recording == nil, ownedDictation == nil, ownedCaptureStartup == nil,
              comparisonCapture == nil, handsFreeRun == nil else { throw DesktopPressCaptureError.occupied }
        capturedCleanup[snapshot.id] = snapshot.cleanup
        defer {
            if ownedDictation?.id != snapshot.id { capturedCleanup.removeValue(forKey: snapshot.id) }
        }
        let textOutput = await snapshot.textOutput.value
        try Task.checkCancellation()
        let (profile, target, deviceID, trigger) = (
            snapshot.profile, snapshot.target, snapshot.deviceID, snapshot.trigger
        )
        let key = snapshot.key
        let configuration = snapshot.configuration
        let localModel = beginLocalUse(profile.modelIdentifier)
        defer { endLocalUse(localModel) }
        let rate = DesktopLiveTranscription.route(forID: profile.modelIdentifier)?.sampleRate
            ?? PCMRecordingFile.sampleRate
        let identity = DesktopPressCaptureIdentity(
            deviceID: deviceID, routeID: profile.modelIdentifier, profileID: profile.profileName ?? "",
            sampleRate: rate,
            frameMilliseconds: DesktopLiveTranscription.captureFrameMilliseconds(forID: profile.modelIdentifier)
        )
        let hints = try await recognitionVocabulary()
        var input = DesktopHostRecordingInput(key: key, azureEndpoint: snapshot.endpoint, vocabulary: hints.keywords)
        input.pronunciationWords = hints.pronunciationWords
        input.voiceCommands = try DesktopHostVoiceCommandPolicy(recorded: configuration)
        guard !closed, !cancellationRequested, !Task.isCancelled else { throw CancellationError() }
        let id = snapshot.id
        await recordingFeedback?.recordingRequested(id)
        guard !closed, !cancellationRequested, !Task.isCancelled else { throw CancellationError() }
        let filename = id.uuidString + ".wav"
        let file: PCMRecordingFile
        do {
            file = try PCMRecordingFile(
                url: directory.appendingPathComponent("History").appendingPathComponent(filename), sampleRate: rate
            )
        } catch {
            await recordingFeedback?.cancelRecording(id)
            throw error
        }
        var record = profileRecord(id: id, filename: filename, profile: profile)
        var live: DesktopLiveSession?
        do {
            try await saveRecord(record)
            guard !closed, !cancellationRequested, !Task.isCancelled else { throw CancellationError() }
            live = try await makeLiveSession(
                model: profile.modelIdentifier, key: key, id: id, language: profile.language,
                options: profile.transcriptionOptions, input: input, polish: snapshot.polish
            )
            if let notice = live?.keywordLimitation, !(record.profileNotes ?? []).contains(notice) {
                record.profileNotes = (record.profileNotes ?? []) + [notice]
                try await saveRecord(record)
            }
            guard !closed, !cancellationRequested, !Task.isCancelled else { throw CancellationError() }
        } catch {
            live?.cancel()
            await recordingFeedback?.cancelRecording(id)
            try await saveStartupFailure(error, record: record, file: file)
            throw error
        }
        let request = DesktopHostOwnedDictationRequest<Platform>(
            record: record, identity: identity, profile: profile, input: input, target: target,
            textOutput: textOutput, trigger: trigger, configuration: configuration,
            tailSeconds: configuration?.number("postRecordingTailDuration") ?? SpeechDefaults.recordingTailDuration,
            live: live
        )
        let owner = DesktopHostOwnedDictationSession(
            request: request, file: file, capability: capability,
            onFailure: { [weak self] in Task { await self?.ownedDictationFailed(requestID: id) } },
            onSilence: { [weak self] in Task { await self?.stopForSilence(recordingID: id) } }
        )
        // Occupy the real Host before the first async native open. This independent
        // operation owns admission until disposition, including a failed retirement.
        beginBusyOperation()
        ownedDictation = .init(id: id, request: request, owner: owner)
        live?.start()
        let ready = await owner.start()
        guard ready, !closed, !Task.isCancelled, ownedDictation?.id == id, ownedDictation?.stop == nil else {
            await stopOwnedDictation(
                requestID: id, reason: Task.isCancelled ? "Recording startup cancelled. Audio retained." : nil
            )
            return
        }
        announceRecording(id, profile: profile, trigger: trigger)
        if let live { monitorLive(live) }
        await notifyRecordingFeedback(id, handsFree: false, captureReady: true)
    }

    func ownedDictationFailed(requestID: UUID) {
        guard ownedDictation?.id == requestID else { return }
        cancelRecordingTail()
        // The correlated session owns the exact failure ledger; do not replace its
        // first cause with a generic Host error or recursively wait on its inbox.
        requestOwnedDictationStop(requestID: requestID)
    }

    func requestOwnedDictationStop(requestID: UUID, reason: String? = nil) {
        guard var active = ownedDictation, active.id == requestID else { return }
        if let reason {
            if active.abortReason == nil { active.abortReason = reason }
            cancelRecordingTail()
            active.owner.abort(reason)
            active.request.live?.livePolish?.cancel()
        }
        guard active.stop == nil, active.failure == nil else { ownedDictation = active; return }
        active.stop = Task { await self.finishOwnedDictation(requestID: requestID, retry: false) }
        ownedDictation = active
    }

    func stopOwnedDictation(requestID: UUID, reason: String? = nil) async {
        requestOwnedDictationStop(requestID: requestID, reason: reason)
        await ownedDictation?.stop?.value
    }

    /// Retry is explicit and request-correlated, including after controller close.
    package func retryOwnedDictation(requestID: UUID) async throws {
        guard var active = ownedDictation, active.id == requestID, let failure = active.failure,
              active.stop == nil else { throw DesktopPressCaptureError.invalidPhase }
        active.failure = nil
        active.stop = Task { await self.finishOwnedDictation(requestID: requestID, retry: failure == .retirement) }
        ownedDictation = active
        await active.stop?.value
    }

    // existing owned dictation-session teardown orchestration; no behavior change.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func finishOwnedDictation(requestID: UUID, retry: Bool) async {
        guard let active = ownedDictation, active.id == requestID else { return }
        defer { if ownedDictation?.id == requestID { ownedDictation?.stop = nil } }
        let phase = await active.owner.phase
        if !retry, active.abortReason == nil, phase == .recording {
            await waitForRecordingTail(recordID: requestID, seconds: active.request.tailSeconds)
        }
        if let reason = ownedDictation?.abortReason { active.owner.abort(reason) }
        liveUpdates?.cancel()
        liveUpdates = nil
        active.request.live?.livePolish?.pause()
        guard var stopped = await active.owner.stop(retry: retry) else {
            ownedDictation?.failure = .retirement
            let message = await active.owner.cleanupFailure ?? "Owned recording is still awaiting safe retirement."
            reportFailure(message, for: requestID, headline: "Capture cleanup needs retry")
            return
        }
        // Cancel/close can arrive while quiescence or retirement is suspended.
        if let reason = ownedDictation?.abortReason, stopped.record.failure == nil {
            var record = stopped.record
            record.failure = reason
            if let live = stopped.live {
                record.result = liveResult(live.cancel().text, record: record, duration: stopped.duration)
            }
            stopped = StoppedRecording(
                record: record, duration: stopped.duration, target: stopped.target, live: stopped.live,
                profile: stopped.profile, textOutput: stopped.textOutput, input: stopped.input
            )
        }
        do {
            if stopped.record.failure != nil || closed || cancellationRequested {
                await recordingFeedback?.cancelRecording(requestID)
                var record = stopped.record
                if record.failure == nil {
                    record.failure = closed ? "Recording stopped when the app closed. Audio retained."
                        : "Recording cancelled. Audio retained."
                }
                try await saveRecord(record)
                if !closed { present(record, output: nil) }
            } else {
                await notifyRecordingFeedback(requestID, handsFree: false)
                if closed || cancellationRequested {
                    try await saveCancelledRecording(
                        stopped, reason: closed ? "Recording stopped when the app closed. Audio retained."
                            : "Recording cancelled. Audio retained."
                    )
                } else {
                    try await processStoppedRecording(stopped)
                    let persisted = try await store.record(id: requestID)
                    guard persisted.result != nil || persisted.failure != nil else {
                        throw DesktopHostError(message: "History has no terminal dictation outcome.")
                    }
                }
            }
        } catch {
            // Safe retirement has completed, but History ownership is not silently
            // discarded. A disposition retry reuses the terminal WAV, never closes twice.
            ownedDictation?.failure = .history
            reportFailure("Owned recording disposition needs retry: \(error)", for: requestID)
            return
        }
        guard ownedDictation?.id == requestID else { return }
        ownedDictation = nil
        capturedCleanup.removeValue(forKey: requestID)
        hotKeySession.startsAfter = ProcessInfo.processInfo.systemUptime
        finishBusyOperation()
    }
}
