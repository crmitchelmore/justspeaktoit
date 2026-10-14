import Foundation
import SpeakCore
import SpeakDesktop

/// The detector alone owns native capture. Each utterance owns only its PCM sink.
final class DesktopHandsFreeRun<Platform: DesktopHostPlatform>: @unchecked Sendable {
    let id: UUID
    let audio: DesktopHandsFreeAudio
    let profile: DesktopProfileSession
    let textOutput: Platform.TextOutputOptions
    let deviceID: String
    var capture: (any DesktopRecordingCapture)?
    var started = false

    init(
        id: UUID, audio: DesktopHandsFreeAudio, profile: DesktopProfileSession,
        textOutput: Platform.TextOutputOptions, deviceID: String
    ) {
        self.id = id
        self.audio = audio
        self.profile = profile
        self.textOutput = textOutput
        self.deviceID = deviceID
    }

    func stopDetector() throws {
        audio.close()
        guard let capture else { return }
        self.capture = nil
        defer { capture.destroy() }
        if started { try capture.stop() }
    }
}

final class DesktopHandsFreeUtteranceCapture: DesktopRecordingCapture {
    let audio: DesktopHandsFreeAudio
    let context: DesktopCaptureContext
    init(audio: DesktopHandsFreeAudio, context: DesktopCaptureContext) {
        self.audio = audio
        self.context = context
    }
    func start() throws { try audio.attach { [context] in context.receiveBuffered($0) } }
    func stop() throws { audio.suspend() }
    func destroy() {}
}

extension DesktopHostController {
    package func handsFreeState() -> HandsFreeDictationMachine.State { handsFreeMachine.state }

    func handsFreeShortcut(_ request: DesktopHostShortcutRequest<Platform>) async -> Bool {
        guard handsFreeMachine.isArmed || (recording == nil &&
            settings.configuration?.enabled("handsFreeDictationEnabled") == true) else { return false }
        guard handsFreeActs(request) else { return true }
        if handsFreeMachine.isArmed { await disarmHandsFree(); return true }
        guard canUseHistory, request.recognisedAt >= hotKeySession.startsAfter else { return true }
        let textOutput = await request.textOutput.value
        guard canUseHistory else { return true }
        guard selectModel(request.modelIndex) else { return true }
        selectMicrophone(request.deviceID)
        beginBusyOperation()
        defer { finishBusyOperation() }
        await armHandsFree(request, textOutput: textOutput)
        return true
    }

    private func handsFreeActs(_ request: DesktopHostShortcutRequest<Platform>) -> Bool {
        switch request.input {
        case .press: request.style.togglesOnPress
        case .gesture(.holdStart): request.style.allowsHold
        case .gesture(.doubleTap): request.style.allowsDoubleTap
        case .gesture(.singleTap): handsFreeMachine.isArmed && request.style.allowsDoubleTap
        case .gesture(.holdEnd): false
        }
    }

    private func armHandsFree(
        _ request: DesktopHostShortcutRequest<Platform>, textOutput: Platform.TextOutputOptions
    ) async {
        let id = UUID()
        _ = handsFreeMachine.handle(.userArmed)
        do {
            if let failure = Platform.handsFreeReadinessFailure() { throw DesktopHostError(message: failure) }
            try await playback.stopAndWait()
            guard !closed else { return }
            guard handsFreeMachine.state == .arming else {
                update("Hands-free arming cancelled.", state: 0)
                return
            }
            if let failure = Platform.handsFreeReadinessFailure() { throw DesktopHostError(message: failure) }
            let profile = resolvedProfile(executablePath: request.targetExecutablePath)
            if let limitation = profile.blockingLimitation { throw DesktopHostError(message: limitation.message) }
            _ = try requireCredentialOrLocalModel(profile.modelIdentifier)
            try requireAzureResource(forLive: profile.modelIdentifier)
            let configuration = try configuration()
            let rate = DesktopLiveTranscription.route(forID: profile.modelIdentifier)?.sampleRate
                ?? PCMRecordingFile.sampleRate
            let audio = DesktopHandsFreeAudio(
                sampleRate: rate, threshold: configuration.number("silenceThreshold"),
                hold: configuration.number("silenceDuration"),
                onEvent: { [weak self] event in Task { await self?.handsFreeEvent(event, runID: id) } },
                onFailure: { [weak self] message in Task { await self?.failHandsFree(message, runID: id) } }
            )
            let run = DesktopHandsFreeRun<Platform>(
                id: id, audio: audio, profile: profile,
                textOutput: textOutput, deviceID: request.deviceID
            )
            handsFreeRun = run
            guard await reserveHandsFreeFeedback(run) else { return }
            if let failure = Platform.handsFreeReadinessFailure() { throw DesktopHostError(message: failure) }
            let context = DesktopCaptureContext(
                onPCM: { audio.receive($0, count: $1) },
                onFailure: { [weak self] message in Task { await self?.failHandsFree(message, runID: id) } }
            )
            let capture = try effects.makeCapture(
                context: context, deviceID: request.deviceID, sampleRate: rate,
                frameMilliseconds: DesktopLiveTranscription.captureFrameMilliseconds(forID: profile.modelIdentifier)
            )
            run.capture = capture
            try capture.start()
            run.started = true
            _ = handsFreeMachine.handle(.detectorStarted)
            audio.resumeListening()
            announceHandsFreeListening(id)
        } catch {
            await disarmHandsFree(status: "Hands-free could not arm: \(error.localizedDescription)")
        }
    }

    private func reserveHandsFreeFeedback(_ run: DesktopHandsFreeRun<Platform>) async -> Bool {
        recordingFeedbackPreview?.cancel()
        await recordingFeedback?.recordingRequested(run.id)
        guard !closed, handsFreeRun?.id == run.id else {
            await recordingFeedback?.cancelRecording(run.id)
            return false
        }
        return true
    }

    private func announceHandsFreeListening(_ id: UUID) {
        update("Hands-free listening (noise can trigger). Cues muted; hotkey or Record disarms.",
               state: 1)
        beginHUD(id, .recording(profile: "Listening (sound activation)"))
    }

    func handsFreeEvent(_ event: HandsFreeDictationMachine.Event, runID: UUID) async {
        guard !closed, let run = handsFreeRun, run.id == runID else { return }
        let effects = handsFreeMachine.handle(event)
        if effects.contains(.startCapture) {
            guard !busy, recording == nil else {
                await disarmHandsFree(status: "Hands-free could not start while another operation was active.")
                return
            }
            beginBusyOperation()
            defer { finishBusyOperation() }
            do {
                let target = try await utteranceTarget(run)
                guard !closed, handsFreeRun?.id == runID else { return }
                try await startRecording(
                    target: target, deviceID: run.deviceID, profile: run.profile,
                    textOutput: run.textOutput, handsFree: run
                )
                guard handsFreeRun?.id == runID, let record = recording else { return }
                update("Hands-free recording. Silence finishes; hotkey or Record disarms and keeps captured audio.",
                       state: 1)
                hud(record.record.id, .recording(profile: "Hands-free"))
            } catch { await failHandsFree(error.localizedDescription, runID: runID) }
        } else if effects.contains(.stopCapture) {
            await finishHandsFree(run)
        }
    }

    private func finishHandsFree(_ run: DesktopHandsFreeRun<Platform>) async {
        while busy {
            guard !closed, handsFreeRun?.id == run.id else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard let recordID = recording?.record.id else {
            await disarmHandsFree(status: "Hands-free could not finish its recording.")
            return
        }
        beginBusyOperation()
        defer { finishBusyOperation() }
        await stopAndTranscribe()
        guard !closed, handsFreeRun?.id == run.id else { return }
        if let record = history[recordID], record.result != nil,
           record.failure == nil, record.postProcessingFailure == nil, !cancellationRequested {
            if outputSlot.recordID == recordID, let delivery = outputSlot.task { await delivery.value }
            guard !closed, handsFreeRun?.id == run.id, !cancellationRequested else { return }
            guard outputSlot.recordID == recordID, let result = outputSlot.result else {
                await disarmHandsFree(
                    status: "Hands-free stopped: no automatic output was delivered. The transcript stays in History."
                )
                return
            }
            guard result.permitsAutomaticResume else {
                await disarmHandsFree(
                    status: "Hands-free stopped. \(result.status) "
                        + "Check the original field before using the hotkey again."
                )
                return
            }
            _ = handsFreeMachine.handle(.captureFinished)
            run.audio.resumeListening()
            announceHandsFreeListening(run.id)
        } else {
            await disarmHandsFree(
                status: "Hands-free stopped after a failed session. Captured audio stays in History."
            )
        }
    }

    private func utteranceTarget(_ run: DesktopHandsFreeRun<Platform>) async throws -> Platform.InsertionTarget? {
        guard Platform.requiresInsertionTarget(run.textOutput) else { return nil }
        guard let target = try await effects.captureInsertionTarget() else {
            throw DesktopHostError(
                message: "No external destination was captured. Focus a text field or select clipboard-only output."
            )
        }
        return target
    }

    func failHandsFree(_ message: String, runID: UUID) async {
        guard handsFreeRun?.id == runID else { return }
        await disarmHandsFree(
            status: "Hands-free stopped: \(message)", recordFailure: "Hands-free capture failed: \(message)"
        )
    }

    package func handsFreeUserAbsent(_ reason: String) async {
        guard handsFreeMachine.isArmed else { return }
        await disarmHandsFree(status: "Hands-free disarmed: \(reason)")
    }

    @discardableResult
    func disarmHandsFree(status: String = "Hands-free disarmed.", recordFailure: String? = nil) async -> String? {
        let run = handsFreeRun
        handsFreeRun = nil
        _ = handsFreeMachine.handle(.userDisarmed)
        run?.audio.close()
        cancellationRequested = true
        cancelRecordingTail()
        transcriptionTask?.cancel()
        postProcessingTask?.cancel()
        liveFinalisation?.cancel()
        cancelOutput()
        var failure: String?
        do { try run?.stopDetector() } catch { failure = error.localizedDescription }
        if recording?.handsFree == true {
            do {
                if let stopped = try stopCapture() {
                    try await saveCancelledRecording(
                        stopped, reason: recordFailure ?? "Recording cancelled. Audio retained."
                    )
                }
            } catch { failure = (failure.map { $0 + " " } ?? "") + error.localizedDescription }
        }
        if let run { await recordingFeedback?.cancelRecording(run.id) }
        if let run { finishHUD(run.id, .success(status)) }
        update(failure.map { "\(status) Cleanup failed: \($0)" } ?? status, state: 0)
        hotKeySession.startsAfter = ProcessInfo.processInfo.systemUptime
        return failure
    }
}
