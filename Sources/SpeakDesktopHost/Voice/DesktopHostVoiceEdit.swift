import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    var voiceEditIsListening: Bool { voiceEdit.active?.phase == .listening }

    /// Only admission is queued with settings. Recording and provider work have
    /// their own cancellable task, so Cancel and shutdown can always reach it.
    package func toggleVoiceEdit(source: DesktopHostVoiceEditSource, deviceID: String) {
        if let run = voiceEdit.active {
            source.cancel()
            guard !closed, run.phase == .listening else { return }
            run.phase = .processing
            voiceEdit.workers += 1
            run.workers += 1
            run.task = Task {
                await processVoiceEdit(run)
                voiceEditWorkerFinished(run)
            }
            return
        }
        guard canUseHistory, outputSlot.task == nil, ownedCaptureStartup == nil, ownedDictation == nil,
              ownedDictationAdmission == nil, !handsFreeMachine.isArmed else {
            source.cancel()
            update("Finish the current operation before editing a selection by voice.")
            return
        }
        let run = DesktopHostVoiceEditRun(
            source: source, profile: resolvedProfile(executablePath: source.executablePath),
            configuration: settings.configuration, processing: postProcessingOptions()
        )
        voiceEdit.active = run
        Platform.voiceEditEscape(true)
        beginBusyOperation()
        voiceEdit.workers += 1
        run.workers += 1
        update("Voice edit: checking the captured selection and model before opening the microphone.", state: 2)
        run.task = Task {
            await prepareVoiceEdit(run, deviceID: deviceID)
            voiceEditWorkerFinished(run)
        }
    }

    private func processVoiceEdit(_ run: DesktopHostVoiceEditRun) async {
        do {
            let duration = try await stopVoiceEditAudio(run)
            await recordingFeedback?.recordingFinished(run.id)
            try checkVoiceEdit(run)
            guard duration > 0, let file = run.file, !file.isDigitalSilence else {
                throw DesktopVoiceEditError.emptyInput
            }
            update("Voice edit: transcribing your instruction.", state: 2)
            hud(run.id, .transcribing())
            let raw: String
            if let live = run.live {
                let result = await live.finish()
                if let error = result.error { throw DesktopHostError(message: error) }
                raw = result.text
            } else {
                var request = DesktopHostTranscriptionRequest(
                    audio: file.url, model: run.profile.modelIdentifier, key: run.transcriptionKey,
                    duration: duration, language: run.profile.language, keywords: run.keywords,
                    azureEndpoint: run.endpoint
                )
                request.historySaved = false
                request.modulateFeatures = run.profile.modulateBatchFeatures
                raw = try await effects.transcribeComparison(request, azureEndpoint: run.endpoint, with: self).text
            }
            try checkVoiceEdit(run)
            let instruction = VoiceEditPolicy.normalizedInstruction(raw)
            guard !instruction.isEmpty else { throw DesktopVoiceEditError.emptyInput }
            update("Voice edit: applying your instruction to the captured text.", state: 2)
            hud(run.id, .init(
                phase: .postProcessing, headline: "Editing selection", subheadline: "Applying your spoken instruction"
            ))
            let rewritten = try await effects.rewriteSelection(.init(
                selection: run.selection, instruction: instruction, model: run.rewriteModel,
                temperature: run.temperature
            ), key: run.key)
            try checkVoiceEdit(run)
            guard !rewritten.isEmpty else { throw OpenRouterClientError.invalidResponse }
            hud(run.id, .delivering(copying: false))
            let delivery = try await run.source.replace(rewritten)
            try checkVoiceEdit(run)
            await retireVoiceEdit(run, status: delivery.status, presentation: delivery.presentation)
        } catch {
            let message = "Voice edit failed: \(error.localizedDescription)"
            await retireVoiceEdit(run, status: message, presentation: .failure(message, headline: "Voice edit failed"))
        }
    }

    func cancelVoiceEdit(
        status: String = "Voice edit cancelled. If delivery had begun, check the original selection.",
        showFailure: Bool = false
    ) {
        guard let run = voiceEdit.active, run.phase != .retired else { return }
        run.phase = .retired
        run.retirementStatus = status
        run.retirementHUD = showFailure ? .failure(status, headline: "Voice edit failed") : .hidden
        run.task?.cancel()
        run.live?.cancel()
        run.source.cancel()
        voiceEdit.workers += 1
        run.workers += 1
        Task {
            await retireVoiceEdit(run, status: status)
            voiceEditWorkerFinished(run)
        }
    }

    func retireVoiceEdit(
        _ run: DesktopHostVoiceEditRun, status: String, presentation: DesktopHUDState = .hidden
    ) async {
        if let retirement = run.retirement { await retirement.value; return }
        run.phase = .retired
        run.live?.cancel()
        run.source.cancel()
        let retirement = Task {
            var message = run.retirementStatus ?? status
            var cleanupFailed = false
            do { _ = try await stopVoiceEditAudio(run) } catch {
                cleanupFailed = true
                if !message.contains(error.localizedDescription) {
                    message += " Instruction audio cleanup failed: \(error.localizedDescription)"
                }
            }
            await recordingFeedback?.cancelRecording(run.id)
            if voiceEdit.active === run {
                voiceEdit.active = nil
                Platform.voiceEditEscape(false)
                if run.busyHeld {
                    run.busyHeld = false
                    finishBusyOperation()
                }
                if !closed {
                    update(message, state: 0)
                    let outcome: DesktopHUDState = cleanupFailed
                        ? .failure(message, headline: "Voice edit cleanup failed")
                        : run.retirementHUD ?? presentation
                    if hudRecording == run.id {
                        finishHUD(run.id, outcome)
                    } else if cleanupFailed || outcome.phase == .failure {
                        failHUDStart(message)
                    }
                } else if cleanupFailed {
                    FileHandle.standardError.write(Data((message + "\n").utf8))
                }
            }
        }
        run.retirement = retirement
        await retirement.value
    }

    private func voiceEditWorkerFinished(_ run: DesktopHostVoiceEditRun) {
        run.workers -= 1
        if run.workers == 0, run.phase == .retired {
            endLocalUse(run.heldModel)
            run.heldModel = nil
            if let owner = run.scratchOwner, run.scratch != nil {
                do { try owner.removeRun(run.id) } catch {
                    let message = "Private voice-edit audio could not be removed: \(error.localizedDescription)"
                    if closed { FileHandle.standardError.write(Data((message + "\n").utf8)) } else { update(message) }
                }
            }
            run.scratchOwner = nil
            run.task = nil
            run.retirement = nil
        }
        voiceEdit.workers -= 1
        if voiceEdit.workers == 0 {
            if closed { voiceEdit.scratchOwner = nil }
            let pending = voiceEdit.waiters
            voiceEdit.waiters = []
            pending.forEach { $0.resume() }
        }
    }

    func voiceEditWorkersEnded() async {
        guard voiceEdit.workers > 0 else {
            if closed { voiceEdit.scratchOwner = nil }
            return
        }
        await withCheckedContinuation { voiceEdit.waiters.append($0) }
    }
}
