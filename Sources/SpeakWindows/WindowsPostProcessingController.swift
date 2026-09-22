import Foundation
import SpeakCore
import SpeakDesktop

extension WindowsAppController {
    func postProcessingOptions() -> DesktopPostProcessing.Options { settings.postProcessing ?? .init() }

    func savePostProcessing(enabled: Bool, modelIndex: Int, prompt: String, key: String) {
        guard !closed, DesktopPostProcessing.remoteModels.indices.contains(modelIndex) else { return }
        do {
            let model = DesktopPostProcessing.remoteModels[modelIndex].id
            let options = DesktopPostProcessing.Options(
                mode: enabled ? .remote : .disabled, modelIdentifier: model,
                customPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
            )
            if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try WindowsNative.saveAPIKey(key, name: postProcessingCredential(for: model))
            }
            var changed = settings
            changed.postProcessing = options
            try JSONEncoder().encode(changed).write(
                to: directory.appendingPathComponent("settings.json"), options: .atomic
            )
            settings = changed
            update(enabled ? "Remote post-processing enabled. Transcripts will be sent to OpenRouter."
                : "Post-processing disabled.")
        } catch { update("Could not save post-processing settings: \(error.localizedDescription)") }
    }

    func postProcess(
        _ original: DesktopRecordingStore.Record, options: DesktopPostProcessing.Options
    ) async -> DesktopRecordingStore.Record {
        var record = original
        guard let result = record.result else { return record }
        if TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(result.text) {
            record.processedText = ""
            return record
        }
        guard !closed, !cancellationRequested, options.mode == .remote else { return record }
        do {
            let key = try WindowsNative.apiKey(
                name: postProcessingCredential(for: options.modelIdentifier)
            )
            update("Polishing transcript… The original is saved in History.", state: 2)
            let task = Task {
                try Task.checkCancellation()
                return try await DesktopPostProcessing.process(rawText: result.text, options: options, apiKey: key)
            }
            postProcessingTask = task
            defer { postProcessingTask = nil }
            let outcome = try await task.value
            record.processedText = outcome.processedText
            record.postProcessingModelIdentifier = outcome.modelIdentifier
        } catch { record.postProcessingFailure = error.localizedDescription }
        return record
    }

    private func postProcessingCredential(for model: String) throws -> String {
        guard case .apiKey(let identifier, _) = ModelCredentialResolver.requirement(
            for: model, purpose: .postProcessing
        ) else { throw DesktopPostProcessingError.unsupportedModel }
        return identifier
    }
}
