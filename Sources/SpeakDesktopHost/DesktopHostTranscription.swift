import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    /// Output is the recording's own authority; imports and retries pass nil.
    package func transcribe(
        _ original: DesktopRecordingStore.Record, duration: TimeInterval, output: DesktopHostRecordingOutput<Platform>?,
        profile: DesktopProfileSession? = nil
    ) async {
        var record = original
        cancellationRequested = false
        // The record's on-device model, a profile's or the app's, stays in use until this finishes.
        let localModel = beginLocalUse(record.modelIdentifier)
        defer { endLocalUse(localModel) }
        let session = profile ?? .defaults(
            modelIdentifier: record.modelIdentifier, postProcessing: settings.postProcessing ?? .init(),
            language: record.languageIdentifier
        )
        do {
            guard !closed else { throw CancellationError() }
            let key = try transcriptionKey(for: record.modelIdentifier)
            let audio = try await store.audioURL(for: record)
            guard !closed else { throw CancellationError() }
            try checkUploadSize(audio, model: record.modelIdentifier)
            update(transcribingStatus(for: record.modelIdentifier), state: 2)
            let request = DesktopHostTranscriptionRequest(
                audio: audio, model: record.modelIdentifier, key: key, duration: duration, language: session.language
            )
            let effects = self.effects
            let task = Task {
                try Task.checkCancellation()
                return try await effects.transcribe(request, with: self)
            }
            transcriptionTask = task
            defer { transcriptionTask = nil }
            let result = try await task.value
            record.result = result
            record.failure = nil
            record.processedText = nil
            record.postProcessingModelIdentifier = nil
            record.postProcessingFailure = session.skippedPolishReason
            try await saveRecord(record)
            record = await postProcess(record, options: session.postProcessing)
            if cancellationRequested { record.failure = "Cancelled. Completed transcription and audio retained." }
            try await saveRecord(record)
            // A response already received is still durably saved during shutdown,
            // but closing must never insert text or update a destroyed window.
            guard !closed else { return }
            present(record, output: output)
        } catch {
            record.failure = cancellationRequested
                ? "Transcription cancelled. Audio retained." : error.localizedDescription
            do { try await saveRecord(record) } catch {
                update("History could not be saved: \(error.localizedDescription)", state: 0)
                return
            }
            update(record.failure ?? "Audio retained in History.", state: 0)
        }
    }

    /// Shows a saved record. Work finishing after `close()` never reaches the
    /// window: its record is already saved, and nothing is output.
    func present(_ record: DesktopRecordingStore.Record, output: DesktopHostRecordingOutput<Platform>?) {
        guard !closed else { return }
        selectedHistoryID = record.id
        transcriptVariant = .processed
        refreshHistory(selectRecord: true)
        transcript = record.displayText ?? ""
        var status = record.failure ?? "Saved to History. Select Copy to use the transcript."
        if let failure = record.postProcessingFailure {
            status = "Original transcript saved; post-processing failed. \(failure)"
        }
        if let output, !transcript.isEmpty, record.failure == nil, record.postProcessingFailure == nil,
           let started = beginOutput(transcript, output: output, recordID: record.id).status {
            status = started
        }
        if selectedHistoryID == record.id {
            Platform.recordingState(0)
            Platform.historyPresentation(record, variant: .processed, status: status + profileContext(record))
        } else {
            // An active search keeps its rows; the result is still shown here.
            status += " This recording is hidden by the current History search."
            update(status + profileContext(record), transcript: transcript, state: 0)
        }
    }

    package func cancelTranscription() {
        guard !closed else { return }
        cancelOutput()
        guard busy else { return }
        cancellationRequested = true
        transcriptionTask?.cancel()
        postProcessingTask?.cancel()
        liveFinalisation?.cancel()
        update("Cancelling… Saved audio and completed results will be retained.", state: 2)
    }
}
