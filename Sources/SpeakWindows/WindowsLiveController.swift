import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import CWindowsSupport

extension WindowsAppController {
    func makeLiveSession(
        for profile: DesktopProfileSession, key: String, id: UUID
    ) async throws -> DesktopLiveSession? {
        try await makeLiveSession(model: profile.modelIdentifier, key: key, id: id, language: profile.language)
    }

    func makeLiveSession(
        model: String, key: String, id: UUID, language: String? = nil
    ) async throws -> DesktopLiveSession? {
        if WindowsModels.isLocalLive(model) {
            return try await makeLocalLiveSession(model: model, id: id, language: language)
        }
        guard WindowsModels.isLive(model), let client = effects.makeLiveClient(
            model: model, key: key, language: language, azureEndpoint: azureResourceEndpoint()
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
                let place = WindowsModels.isLocalLive(recording?.record.modelIdentifier ?? "") ? " on this PC" : ""
                let status = "Live transcription\(place)… "
                    + hotKeySettings().finishHint(for: recording?.trigger ?? .other)
                    + (recording.map { profileContext($0.record) } ?? "")
                update(status, transcript: snapshot.text, state: 1)
            }
        }
    }

    func finishLive(_ stopped: StoppedRecording, session: DesktopLiveSession) async {
        var record = stopped.record
        cancellationRequested = false
        // An on-device live model decodes the tail after capture ends; keep it.
        let localModel = beginLocalUse(record.modelIdentifier)
        defer { endLocalUse(localModel) }
        liveFinalisation = session
        defer { liveFinalisation = nil }
        let options = stopped.profile.postProcessing
        update("Finishing live transcript… Audio is saved locally.", state: 2)
        let snapshot = await session.finish()
        record.result = liveResult(snapshot.text, record: record, duration: stopped.duration)
        record.failure = snapshot.error
        record.postProcessingFailure = stopped.profile.skippedPolishReason
        if cancellationRequested || closed || snapshot.phase == .cancelled {
            record.failure = "Live transcription cancelled. Audio and received text retained."
        }
        do {
            try await saveRecord(record)
            if record.failure == nil { record = await postProcess(record, options: options) }
            if cancellationRequested { record.failure = "Cancelled. Completed transcription and audio retained." }
            try await saveRecord(record)
            if !closed { present(record, output: stopped.output) }
        } catch {
            update("Live recording retained; history could not be saved: \(error.localizedDescription)", state: 0)
        }
    }

    func liveResult(
        _ text: String, record: DesktopRecordingStore.Record, duration: TimeInterval
    ) -> TranscriptionResult {
        let cleaned = TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(text) ? "" : text
        return TranscriptionResult(
            text: cleaned, segments: [], confidence: nil, duration: duration,
            modelIdentifier: record.modelIdentifier, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }

    func preferredModelIDs() -> WindowsModelPreferences {
        WindowsModelPreferences(
            batch: settings.batchModel, live: settings.liveModel, local: settings.localModel,
            localLive: settings.localLiveModel
        )
    }
}
