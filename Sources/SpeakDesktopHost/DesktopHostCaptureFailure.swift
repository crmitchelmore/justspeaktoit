import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    func captureFailed(_ message: String, recordingID: UUID) async {
        if !closed, ownedDictation?.id == recordingID {
            await stopOwnedDictation(requestID: recordingID, reason: message)
            return
        }
        guard !closed, recording?.record.id == recordingID else { return }
        invalidateConnectionPreWarming(resetCapture: true)
        if recording?.handsFree == true, let runID = handsFreeRun?.id {
            await failHandsFree(message, runID: runID)
            return
        }
        await recordingFeedback?.cancelRecording(recordingID)
        beginBusyOperation()
        defer {
            capturedCleanup.removeValue(forKey: recordingID)
            finishBusyOperation()
        }
        var record = recording?.record
        let live = recording?.live
        var stopped: StoppedRecording?
        var failure = message
        do { stopped = try stopCapture() } catch {
            failure += " Capture cleanup failed: \(error.localizedDescription)"
        }
        if let live, var partial = record {
            let snapshot = live.cancel()
            partial.result = liveResult(snapshot.text, record: partial, duration: stopped?.duration ?? 0)
            record = partial
        }
        record?.failure = failure
        do { if let record { try await saveRecord(record) } } catch {
            update("\(message) History error: \(error.localizedDescription)", state: 0)
            return
        }
        if let record { await presentCancelledRecording(record) } else {
            reportFailure("Recording stopped and retained: \(message)", for: recordingID, headline: "Recording stopped")
        }
    }
}
