import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    func makeLiveSession(
        model: String, key: String, id: UUID, language: String? = nil, options: LiveClientOptions? = nil,
        azureEndpoint: String? = nil,
        input: DesktopHostRecordingInput? = nil, polish: DesktopHostLivePolishInput? = nil
    ) async throws -> DesktopLiveSession? {
        if DesktopHostModels.isLocalLive(model) {
            // On-device streaming has no provider vocabulary, keyterms or endpoint.
            guard let client = try await Platform.makeLocalLiveClient(model, language: language, controller: self)
            else { return nil }
            return DesktopLiveSession(
                client: client, id: id, keywordLimitation: nil, livePolish: makeLivePolish(polish, id: id)
            )
        }
        guard DesktopHostModels.isLive(model) else { return nil }
        let baseOptions = options ?? settings.configuration?.liveOptions ?? .desktopDefaults
        let hints: (keywords: [String], pronunciationWords: [String])
        if let input { hints = (input.vocabulary, input.pronunciationWords) } else {
            hints = try await recognitionVocabulary()
        }
        let recognition = DesktopHostModels.provider(for: model)?.id == "assemblyai"
            ? baseOptions.includingPronunciationWords(hints.pronunciationWords) : baseOptions
        let options = recognition.includingVocabularyKeywords(hints.keywords)
        guard let client = effects.makeLiveClient(
            model: model, key: key, language: language,
            azureEndpoint: input?.azureEndpoint ?? azureEndpoint ?? azureResourceEndpoint(), options: options
        ) else { return nil }
        return DesktopLiveSession(
            client: client, id: id,
            keywordLimitation: options.keywords.isEmpty ? nil : DesktopTranscription.keywordLimitation(model: model),
            livePolish: makeLivePolish(polish, id: id)
        )
    }

    func monitorLive(_ session: DesktopLiveSession) {
        liveUpdates?.cancel()
        selectedHistoryID = session.snapshot().id
        transcriptVariant = .processed
        refreshHistory(selectRecord: true)
        transcript = ""
        if let id = selectedHistoryID, let record = history[id] { showTranscriptVariant(.processed, for: record) }
        liveUpdates = Task {
            var revision: UInt64?
            var displayed: String?
            var polishFailure: String?
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                let snapshot = session.snapshot()
                guard !closed, recording?.record.id == snapshot.id || ownedDictation?.id == snapshot.id else { return }
                if let error = snapshot.error {
                    await captureFailed(error, recordingID: snapshot.id)
                    return
                }
                let cleaned = session.livePolish?.snapshot()
                let preview = cleaned?.succeeded == true && cleaned?.input == snapshot.text
                    ? cleaned?.text ?? snapshot.text : snapshot.text
                guard revision != snapshot.revision || displayed != preview
                    || polishFailure != cleaned?.failure else { continue }
                revision = snapshot.revision
                displayed = preview
                polishFailure = cleaned?.failure
                publishLivePreview(session)
            }
        }
    }

    /// Also permits deterministic presentation tests without driving a wall-clock poll.
    func publishLivePreview(_ session: DesktopLiveSession) {
        let snapshot = session.snapshot()
        guard !closed, snapshot.phase == .recording || snapshot.phase == .finishing,
              recording?.record.id == snapshot.id || ownedDictation?.id == snapshot.id else { return }
        let cleaned = session.livePolish?.snapshot()
        let preview = cleaned?.succeeded == true && cleaned?.input == snapshot.text
            ? cleaned?.text ?? snapshot.text : snapshot.text
        transcript = preview
        let buffering = recordingTail?.recordID == snapshot.id
        let hint = Platform.finishHint(
            hotKeySettings(), for: recording?.trigger ?? ownedDictation?.request.trigger ?? .other
        )
        var status = buffering ? recordingBufferStatus : "Live transcription… " + hint
            + (recording.map { profileContext($0.record) }
                ?? ownedDictation.map { profileContext($0.request.record) } ?? "")
        if let failure = cleaned?.failure { status += " Auto-Clean: \(failure)" }
        update(status, transcript: preview, state: buffering ? 2 : 1)
        hud(snapshot.id, .recording(
            profile: recording?.profile.profileName ?? ownedDictation?.request.profile.profileName,
            liveText: preview
        ))
    }

    func finishLive(_ stopped: StoppedRecording, session: DesktopLiveSession) async {
        defer { capturedCleanup.removeValue(forKey: stopped.record.id) }
        var record = stopped.record
        cancellationRequested = false
        liveFinalisation = session
        defer { liveFinalisation = nil }
        let options = stopped.profile.postProcessing
        update("Finishing live transcript… Audio is saved locally.", state: 2)
        hud(record.id, .transcribing(live: true))
        let snapshot = await session.finish()
        record.result = liveResult(snapshot.text, record: record, duration: stopped.duration)
        record.failure = snapshot.error
        record.postProcessingFailure = stopped.profile.skippedPolishReason
        if cancellationRequested || closed || snapshot.phase == .cancelled {
            record.failure = "Live transcription cancelled. Audio and received text retained."
        }
        do {
            try await saveRecord(record)
            if record.failure == nil {
                record = try await applyVoiceCommands(record, policy: stopped.voiceCommands)
                record = try await applyVocabulary(record)
                record = await applyLivePolish(record, session: session)
                let skip = record.livePolishResult?.succeeded == true
                    && session.livePolish?.preferences.skipPostProcessing == true
                if !skip {
                    record = await postProcess(record, options: options, inputText: record.processedText)
                }
            } else {
                session.livePolish?.cancel()
            }
            if cancellationRequested { record.failure = "Cancelled. Completed transcription and audio retained." }
            try await saveRecord(record)
            if cancellationRequested, record.failure == nil {
                record.failure = "Cancelled. Completed transcription and audio retained."
                try await saveRecord(record)
            }
            if !closed { present(record, output: cancellationRequested ? nil : stopped.output) }
        } catch {
            record.failure = cancellationRequested || closed
                ? "Live transcription cancelled. Audio and received text retained."
                : "Live transcript retained; voice commands or corrections failed. \(error.localizedDescription)"
            do { try await saveRecord(record) } catch {
                reportFailure(
                    "Live recording retained; history could not be saved: \(error.localizedDescription)", for: record.id
                )
                return
            }
            reportFailure(
                record.failure ?? "Live transcript retained.", for: record.id
            )
        }
    }

    func liveResult(
        _ text: String, record: DesktopRecordingStore.Record, duration: TimeInterval
    ) -> TranscriptionResult {
        DesktopHostRecordingStop.liveResult(text, model: record.modelIdentifier, duration: duration)
    }

    package func preferredModelIDs() -> DesktopHostModelPreferences {
        DesktopHostModelPreferences(
            batch: settings.batchModel, live: settings.liveModel, local: settings.localModel,
            localLive: settings.localLiveModel
        )
    }
}
