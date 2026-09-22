import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import CWindowsSupport

extension WindowsAppController {
    func makeLiveSession(model: String, key: String, id: UUID) -> DesktopLiveSession? {
        guard WindowsModels.isLive(model), let client = DesktopLiveTranscription.makeClient(
            model: model, apiKey: key, makeConnection: { WinHTTPStreamingConnection(request: $0) }
        ) else { return nil }
        return DesktopLiveSession(client: client, id: id)
    }

    func monitorLive(_ session: DesktopLiveSession) {
        liveUpdates?.cancel()
        selectedHistoryID = session.snapshot().id
        transcriptVariant = .processed
        refreshHistory()
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
                let status = "Live transcription… Ctrl+Alt+Space to finish."
                    + (recording.map { profileContext($0.record) } ?? "")
                update(status, transcript: snapshot.text, state: 1)
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
            if !closed { present(record, target: stopped.target) }
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

    func preferredModelIDs() -> (batch: String?, live: String?) { (settings.batchModel, settings.liveModel) }
}
