import AppKit
import AVFoundation
import Foundation

// MARK: - Session diagnostics and failure handling (extracted from MainManager)

extension MainManager {
    func ensureBatchAPIKeyAvailable(for session: ActiveSession, message: String) async -> Bool {
        guard await transcriptionManager.hasValidBatchAPIKey() else {
            await handleMissingAPIKey(session, phase: .transcription, message: message)
            return false
        }
        return true
    }

    func ensurePostProcessingAPIKeyAvailable(for session: ActiveSession, message: String) async -> Bool {
        guard await postProcessingManager.hasRequiredAPIKey() else {
            await handleMissingAPIKey(session, phase: .postProcessing, message: message)
            return false
        }
        return true
    }

    func handleMissingAPIKey(_ session: ActiveSession, phase: HistoryError.Phase, message: String) async {
        session.errors.append(HistoryError(phase: phase, message: message, debugDescription: nil))
        session.events.append(HistoryEvent(kind: .error, description: message))
        hudManager.finishFailure(message: message)
        state = .failed(message)
        lastErrorMessage = message
        attachFailureDiagnostics(to: session)
        let historyItem = session.buildHistoryItem(finalText: session.transcriptionResult?.text)
        await historyManager.append(historyItem)
        activeSession = nil
    }

    func cleanupAfterFailure(message: String, preserveFile: Bool) {
        lastErrorMessage = message
        hudManager.finishFailure(message: message)
        state = .failed(message)
        stopAudioLevelMonitoring()
        livePolishManager.reset()
        liveTextInserter.reset()
        if isStreamingTranscriptionMode { transcriptionManager.cancelLiveTranscription() }
        if let session = activeSession { attachFailureDiagnostics(to: session) }
        Task { [failedSession = activeSession] in
            await audioFileManager.cancelRecording(deleteFile: !preserveFile)
            if let session = failedSession {
                let historyItem = session.buildHistoryItem(finalText: session.transcriptionResult?.text)
                await historyManager.append(historyItem)
            }
        }
        activeSession = nil
    }

    func stopRecordingWithTimeout() async throws -> RecordingSummary {
        let timeout = recordingStopTimeout
        let audioFileManager = self.audioFileManager
        return try await withThrowingTaskGroup(of: RecordingSummary.self) { group in
            group.addTask { try await audioFileManager.stopRecording() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SessionStopError.recordingStopTimedOut(seconds: timeout)
            }
            guard let summary = try await group.next() else {
                throw SessionStopError.recordingStopTimedOut(seconds: timeout)
            }
            group.cancelAll()
            return summary
        }
    }

    func getFocusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var rawFocused: CFTypeRef?
        let copyStatus = AXUIElementCopyAttributeValue(
            systemWideElement, kAXFocusedUIElementAttribute as CFString, &rawFocused
        )
        guard copyStatus == .success, let rawFocused else { return nil }
        return unsafeBitCast(rawFocused, to: AXUIElement.self)
    }

}
