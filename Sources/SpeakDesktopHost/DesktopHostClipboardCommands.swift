import Foundation
import SpeakCore
import SpeakDesktop

struct DesktopHostFinalTranscriptTasks: Sendable {
    var postProcessing: Task<DesktopPostProcessing.Outcome, Error>?
    var clipboard: (id: UUID, task: Task<String, Error>)?

    func cancel() {
        postProcessing?.cancel()
        clipboard?.task.cancel()
    }
}

extension DesktopHostController {
    func transformFinalTranscript(
        _ original: DesktopRecordingStore.Record, options: DesktopHostRecordingConfiguration?,
        postProcessing: DesktopPostProcessing.Options
    ) async throws -> DesktopRecordingStore.Record {
        var record = original
        guard let result = record.result else { return record }
        var text = result.text
        if let options {
            do {
                text = try await clipboardCommandText(text, options: options)
            } catch { record.failure = clipboardCommandFailure(error) }
        }
        guard record.failure == nil else { return record }
        record = try await applyVocabulary(record, input: text)
        return await postProcess(record, options: postProcessing)
    }

    func clipboardCommandText(_ text: String, options: DesktopHostRecordingConfiguration) async throws -> String {
        guard !closed, !cancellationRequested else { throw CancellationError() }
        guard finalTranscriptTasks.clipboard == nil else {
            throw DesktopHostError(message: "A clipboard command is already being finalized.")
        }
        // A recorded absence means canonical defaults, never the current settings.
        let policy = try (options.configuration ?? DesktopConfiguration()).clipboardVoiceCommandPolicy
        let effects = self.effects
        let identifier = UUID()
        let task = Task {
            try await DesktopClipboardVoiceCommands.process(text, policy: policy) {
                try await effects.readClipboardText()
            }
        }
        finalTranscriptTasks.clipboard = (identifier, task)
        defer {
            if finalTranscriptTasks.clipboard?.id == identifier { finalTranscriptTasks.clipboard = nil }
        }
        let expanded = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard finalTranscriptTasks.clipboard?.id == identifier, !closed, !cancellationRequested else {
            throw CancellationError()
        }
        return expanded
    }

    func clipboardCommandFailure(_ error: Error) -> String {
        if cancellationRequested || closed || error is CancellationError {
            return "Cancelled. Completed transcription and audio retained."
        }
        return "Clipboard voice command failed: \(error.localizedDescription)"
    }
}
