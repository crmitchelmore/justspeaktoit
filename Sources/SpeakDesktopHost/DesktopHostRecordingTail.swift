import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    var recordingBufferStatus: String {
        "Finishing recording buffer. Cancel keeps captured audio without transcription."
    }

    func stopAndTranscribe() async {
        let pending = recording?.record
        let live = recording?.live
        let handsFree = recording?.handsFree == true
        do {
            guard let id = pending?.id else { return }
            cancellationRequested = false
            await waitForRecordingTail(recordID: id)
            guard !closed, recording?.record.id == id else { return }
            guard let stopped = try stopCapture() else { return }
            if cancellationRequested || Task.isCancelled {
                await recordingFeedback?.cancelRecording(id)
                try await saveCancelledRecording(stopped)
                return
            }
            await notifyRecordingFeedback(id, handsFree: handsFree)
            guard !closed else { return }
            try await processStoppedRecording(stopped)
        } catch {
            if let id = pending?.id { await recordingFeedback?.cancelRecording(id) }
            if var pending {
                pending.failure = error.localizedDescription
                if let live { pending.result = liveResult(live.cancel().text, record: pending, duration: 0) }
                do { try await saveRecord(pending) } catch {
                    update("Recording and history error: \(error.localizedDescription)", state: 0)
                    return
                }
                present(pending, output: nil)
                return
            }
            update("Recording retained: \(error.localizedDescription)", state: 0)
        }
    }

    func notifyRecordingFeedback(_ id: UUID, handsFree: Bool, captureReady: Bool = false) async {
        // Sound activation must not hear our own automatic cues.
        if handsFree { await recordingFeedback?.cancelRecording(id) } else if captureReady {
            await recordingFeedback?.captureReady(id)
        } else {
            await recordingFeedback?.recordingFinished(id)
        }
    }

    private func processStoppedRecording(_ stopped: StoppedRecording) async throws {
        guard stopped.duration > 0 else {
            stopped.live?.cancel()
            var empty = stopped.record
            empty.failure = "No audio was captured."
            try await saveRecord(empty)
            reportFailure("No audio was captured.", for: empty.id, headline: "Nothing was recorded")
            return
        }
        if let live = stopped.live {
            await finishLive(stopped, session: live)
        } else {
            await transcribe(
                stopped.record, duration: stopped.duration, output: stopped.output, profile: stopped.profile,
                azureEndpoint: stopped.options.azureEndpoint
            )
        }
    }

    /// Capture and live delivery stay active until the tail ends. Every abort
    /// takes ownership of the capture before waking this stop request.
    func waitForRecordingTail(recordID: UUID) async {
        let seconds = settings.configuration?.number("postRecordingTailDuration")
            ?? SpeechDefaults.recordingTailDuration
        guard seconds > 0 else { return }
        Platform.recordingState(2)
        update(recordingBufferStatus, state: 2)
        let task = Task<Void, Never> {
            // Cancellation ends the buffer immediately; the owner decides
            // whether to retain cancelled audio or has already taken capture.
            try? await Task.sleep(for: .seconds(seconds))
        }
        recordingTail = (recordID, task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if recordingTail?.recordID == recordID { recordingTail = nil }
    }

    func cancelRecordingTail() {
        recordingTail?.task.cancel()
        recordingTail = nil
    }

    func saveCancelledRecording(
        _ stopped: StoppedRecording, reason: String = "Recording cancelled. Audio retained."
    ) async throws {
        var record = stopped.record
        if let live = stopped.live {
            record.result = liveResult(live.cancel().text, record: record, duration: stopped.duration)
        }
        record.failure = reason
        try await saveRecord(record)
        present(record, output: nil)
    }
}
