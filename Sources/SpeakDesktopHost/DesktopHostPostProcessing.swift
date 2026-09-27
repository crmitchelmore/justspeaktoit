import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    package func postProcessingOptions() -> DesktopPostProcessing.Options { settings.postProcessing ?? .init() }

    /// Saves the dialog's Apply. A typed key is saved first, and a blank field
    /// keeps the saved one. With iCloud sync the key goes through the same step
    /// as the Settings key field, so a deletion synced from the Mac cannot
    /// remove it; the choices are then applied to the settings as they are
    /// after that save, and not at all if the controller closed meanwhile.
    package func savePostProcessing(enabled: Bool, modelIndex: Int, prompt: String, key: String) async {
        guard !closed, DesktopPostProcessing.remoteModels.indices.contains(modelIndex) else { return }
        do {
            let model = DesktopPostProcessing.remoteModels[modelIndex].id
            let options = DesktopPostProcessing.Options(
                mode: enabled ? .remote : .disabled, modelIdentifier: model,
                customPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
            )
            let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty {
                let identifier = try postProcessingCredential(for: model)
                if let saveByHand = cloudSync.saveKeyByHand {
                    try await saveByHand(typed, identifier)
                    guard !closed else { return }
                } else {
                    try Platform.saveAPIKey(typed, name: identifier)
                }
            }
            var changed = settings
            changed.postProcessing = options
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
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
            let key = try Platform.apiKey(
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
