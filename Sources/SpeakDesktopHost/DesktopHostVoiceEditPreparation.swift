import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    // swiftlint:disable:next function_body_length
    func prepareVoiceEdit(_ run: DesktopHostVoiceEditRun, deviceID: String) async {
        do {
            if let limitation = run.profile.blockingLimitation {
                throw DesktopHostError(message: limitation.message)
            }
            guard run.temperature.isFinite, (0...1).contains(run.temperature) else {
                throw DesktopPostProcessingError.invalidTemperature
            }
            run.key = try effects.apiKey(name: postProcessingCredential(for: run.rewriteModel))
            guard !run.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DesktopHostError(message: "Voice editing needs an OpenRouter key. Open API Keys first.")
            }
            run.transcriptionKey = try requireCredentialOrLocalModel(run.profile.modelIdentifier)
            try requireAzureResource(forLive: run.profile.modelIdentifier)
            run.endpoint = azureResourceEndpoint()
            run.selection = try await run.source.capture()
            try checkVoiceEdit(run)
            guard !run.selection.isEmpty else { throw DesktopVoiceEditError.emptyInput }
            cancelOutput()
            try await playback.stopAndWait()
            try checkVoiceEdit(run)
            let hints = try await recognitionVocabulary()
            try checkVoiceEdit(run)
            let options = (run.profile.transcriptionOptions ?? run.configuration?.liveOptions ?? .desktopDefaults)
                .includingPronunciationWords(hints.pronunciationWords)
            run.keywords = batchKeywords(for: run.profile.modelIdentifier, options: options) + hints.keywords
            run.heldModel = beginLocalUse(run.profile.modelIdentifier)
            let base = directory.appendingPathComponent("VoiceEdit", isDirectory: true)
            let scratch = base.appendingPathComponent(run.id.uuidString, isDirectory: true)
            try Platform.preparePrivateDirectory(base)
            try Platform.preparePrivateDirectory(scratch)
            run.scratch = scratch
            let rate = DesktopLiveTranscription.route(forID: run.profile.modelIdentifier)?.sampleRate
                ?? PCMRecordingFile.sampleRate
            run.file = try PCMRecordingFile(
                url: scratch.appendingPathComponent("instruction.wav"), sampleRate: rate
            )
            run.live = try await makeLiveSession(
                model: run.profile.modelIdentifier, key: run.transcriptionKey, id: run.id,
                language: run.profile.language, options: options, azureEndpoint: run.endpoint
            )
            try checkVoiceEdit(run)
            if DesktopHostModels.isLive(run.profile.modelIdentifier)
                || DesktopHostModels.isLocalLive(run.profile.modelIdentifier) {
                guard run.live != nil else { throw DesktopTranscriptionError.unsupportedModel }
            }
            await recordingFeedback?.recordingRequested(run.id)
            try checkVoiceEdit(run)
            try startVoiceEditCapture(run, deviceID: deviceID, rate: rate)
            await recordingFeedback?.captureReady(run.id)
            try checkVoiceEdit(run)
            run.phase = .listening
            run.task = nil
            update(
                "Voice edit: listening for your instruction. Press Edit Selection by Voice again to finish; "
                    + "Cancel stops without editing.", state: 1
            )
            beginHUD(run.id, .init(
                phase: .recording, headline: "Voice edit", subheadline: "Speak your editing instruction"
            ))
        } catch {
            run.live?.cancel()
            let message = "Voice edit failed: \(error.localizedDescription)"
            await retireVoiceEdit(run, status: message, presentation: .failure(message, headline: "Voice edit failed"))
        }
    }

    private func startVoiceEditCapture(_ run: DesktopHostVoiceEditRun, deviceID: String, rate: Int) throws {
        try checkVoiceEdit(run)
        guard let file = run.file else { throw DesktopHostError(message: "Instruction audio was not prepared.") }
        run.live?.start()
        let id = run.id
        let context = DesktopCaptureContext(file: file, live: run.live, sampleRate: rate) { [weak self] message in
            Task { await self?.voiceEditCaptureFailed(id: id, message: message) }
        }
        let capture = try effects.makeCapture(
            context: context, deviceID: deviceID, sampleRate: rate,
            frameMilliseconds: DesktopLiveTranscription.captureFrameMilliseconds(forID: run.profile.modelIdentifier)
        )
        run.capture = capture
        try capture.start()
    }

    func checkVoiceEdit(_ run: DesktopHostVoiceEditRun) throws {
        try Task.checkCancellation()
        guard !closed, voiceEdit.active === run, run.phase != .retired else { throw CancellationError() }
    }

    func voiceEditCaptureFailed(id: UUID, message: String) {
        guard voiceEdit.active?.id == id else { return }
        cancelVoiceEdit(status: "Voice edit microphone failed: \(message)", showFailure: true)
    }
}
