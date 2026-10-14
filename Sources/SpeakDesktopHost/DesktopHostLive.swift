import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    func makeLiveSession(
        model: String, key: String, id: UUID, language: String? = nil,
        options: DesktopHostRecordingConfiguration
    ) async throws -> DesktopLiveSession? {
        guard DesktopHostModels.isLive(model) else { return nil }
        let liveOptions = (options.configuration?.liveOptions ?? .init())
            .includingVocabularyKeywords(try await vocabularyKeywords())
        guard let client = effects.makeLiveClient(
            model: model, key: key, language: language, azureEndpoint: options.azureEndpoint, options: liveOptions
        ) else { return nil }
        return DesktopLiveSession(client: client, id: id)
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
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                let snapshot = session.snapshot()
                guard !closed, recording?.record.id == snapshot.id else { return }
                if let error = snapshot.error {
                    await captureFailed(error, recordingID: snapshot.id)
                    return
                }
                guard revision != snapshot.revision else { continue }
                revision = snapshot.revision
                transcript = snapshot.text
                let buffering = recordingTail?.recordID == snapshot.id
                let hint = Platform.finishHint(hotKeySettings(), for: recording?.trigger ?? .other)
                let status = buffering ? recordingBufferStatus : "Live transcription… " + hint
                    + (recording.map { profileContext($0.record) } ?? "")
                update(status, transcript: snapshot.text, state: buffering ? 2 : 1)
                hud(snapshot.id, .recording(profile: recording?.profile.profileName, liveText: snapshot.text))
            }
        }
    }

    func finishLive(_ stopped: StoppedRecording, session: DesktopLiveSession) async {
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
                record = try await applyVocabulary(record)
                record = await postProcess(record, options: options)
            }
            if cancellationRequested { record.failure = "Cancelled. Completed transcription and audio retained." }
            try await saveRecord(record)
            if !closed { present(record, output: stopped.output) }
        } catch {
            reportFailure(
                "Live recording retained; history could not be saved: \(error.localizedDescription)", for: record.id
            )
        }
    }

    func liveResult(
        _ text: String, record: DesktopRecordingStore.Record, duration: TimeInterval
    ) -> TranscriptionResult {
        DesktopHostRecordingStop.liveResult(text, model: record.modelIdentifier, duration: duration)
    }

    package func preferredModelIDs() -> DesktopHostModelPreferences {
        DesktopHostModelPreferences(batch: settings.batchModel, live: settings.liveModel, local: settings.localModel)
    }
}
