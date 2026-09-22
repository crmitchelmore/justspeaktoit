import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import CWindowsSupport

extension WindowsAppController {
    func transcribe(
        _ original: DesktopRecordingStore.Record, duration: TimeInterval, target: WindowsInsertionTarget?
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
                return try await transcribePreparedAudio(audio, model: model, key: key, duration: duration)
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

    func present(_ record: DesktopRecordingStore.Record, target: WindowsInsertionTarget?) {
        selectedHistoryID = record.id
        transcriptVariant = .processed
        refreshHistory()
        transcript = record.displayText ?? ""
        var status = record.failure ?? "Saved to History. Select Copy to use the transcript."
        if let failure = record.postProcessingFailure {
            status = "Original transcript saved; post-processing failed. \(failure)"
        }
        if let target, !transcript.isEmpty, !closed, record.failure == nil, record.postProcessingFailure == nil {
            status = deliver(transcript, to: target)
        }
        if selectedHistoryID == record.id {
            showTranscriptVariant(.processed, for: record)
        } else {
            // An active search keeps its rows; the result is still shown here.
            status += " This recording is hidden by the current History search."
        }
        update(status, transcript: transcript, state: 0)
    }

    /// Delivers a finished transcript to the field captured at the hotkey.
    /// The native adapter re-verifies that field first, so a changed focus,
    /// a password field or an elevated application ends in the Copy fallback.
    func deliver(_ text: String, to target: WindowsInsertionTarget) -> String {
        let options = settings.textOutput ?? .init()
        guard options.method != .clipboardOnly else {
            do {
                try text.withCString { pointer in
                    try WindowsNative.checked { jsti_clipboard_write(pointer, $0, $1) }
                }
                return "Transcript copied to the clipboard and saved to History."
            } catch {
                return "Saved. The transcript could not be copied; select Copy. \(error.localizedDescription)"
            }
        }
        do {
            return WindowsInsertionStatus.message(for: try target.insert(text, options: options))
        } catch let failure as WindowsTextOutputError {
            return WindowsInsertionStatus.message(for: failure)
        } catch {
            return "Saved. Automatic insertion unavailable; select Copy. \(error.localizedDescription)"
        }
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
