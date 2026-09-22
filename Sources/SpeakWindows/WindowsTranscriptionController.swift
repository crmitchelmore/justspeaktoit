import Foundation
import SpeakCore
import SpeakDesktop
import CWindowsSupport

extension WindowsAppController {
    func transcribe(
        _ original: DesktopRecordingStore.Record, duration: TimeInterval, target: JSTITextTarget?
    ) async {
        var record = original
        cancellationRequested = false
        let processingOptions = settings.postProcessing ?? .init()
        do {
            guard !closed else { throw CancellationError() }
            let key = try WindowsNative.apiKey(name: credentialIdentifier(for: record.modelIdentifier))
            let audio = try await store.audioURL(for: record)
            guard !closed else { throw CancellationError() }
            let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 25_000_000 else {
                throw WindowsNativeError(
                    message: "Audio exceeds this Windows preview’s 25 MB upload cap. The recording is saved."
                )
            }
            update("Transcribing… Your recording is saved locally.", state: 2)
            let model = record.modelIdentifier
            let task = Task {
                try Task.checkCancellation()
                return try await DesktopTranscription.transcribe(
                    audioURL: audio, model: model, apiKey: key, duration: duration, staging: uploadStaging
                )
            }
            transcriptionTask = task
            defer { transcriptionTask = nil }
            let result = try await task.value
            record.result = result
            record.failure = nil
            record.processedText = nil
            record.postProcessingModelIdentifier = nil
            record.postProcessingFailure = nil
            try await saveRecord(record)
            record = await postProcess(record, options: processingOptions)
            if cancellationRequested { record.failure = "Cancelled. Completed transcription and audio retained." }
            try await saveRecord(record)
            // A response already received is still durably saved during shutdown,
            // but closing must never insert text or update a destroyed window.
            guard !closed else { return }
            present(record, target: target)
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

    func present(_ record: DesktopRecordingStore.Record, target: JSTITextTarget?) {
        selectedHistoryID = record.id
        refreshHistory()
        transcript = record.displayText ?? ""
        var status = record.failure ?? "Saved to History. Select Copy to use the transcript."
        if let failure = record.postProcessingFailure {
            status = "Original transcript saved; post-processing failed. \(failure)"
        }
        if var target, !transcript.isEmpty, !closed, record.failure == nil, record.postProcessingFailure == nil {
            do {
                try transcript.withCString { text in
                    try WindowsNative.checked { jsti_target_insert_text(&target, text, $0, $1) }
                }
                status = "Inserted into the original text field and saved to History."
            } catch {
                status = "Saved. Automatic insertion unavailable; select Copy. \(error.localizedDescription)"
            }
        }
        update(status, transcript: transcript, state: 0)
    }

    func cancelTranscription() {
        guard !closed, busy else { return }
        cancellationRequested = true
        transcriptionTask?.cancel()
        postProcessingTask?.cancel()
        liveFinalisation?.cancel()
        update("Cancelling… Saved audio and completed results will be retained.", state: 2)
    }
}
