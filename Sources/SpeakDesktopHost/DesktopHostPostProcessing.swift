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
        guard DesktopPostProcessing.remoteModels.indices.contains(modelIndex) else {
            update("Could not save post-processing settings: invalid remote model selection.")
            return
        }
        await savePostProcessing(
            enabled: enabled, modelIdentifier: DesktopPostProcessing.remoteModels[modelIndex].id,
            prompt: prompt, key: key
        )
    }

    package func savePostProcessing(
        enabled: Bool, modelIdentifier model: String, prompt: String, key: String,
        includeLexiconDirectives: Bool? = nil, includeContextTags: Bool? = nil
    ) async {
        guard !closed else { return }
        do {
            guard let mode = DesktopPostProcessing.mode(for: model) else {
                throw DesktopPostProcessingError.unsupportedModel
            }
            guard mode != .localLLM || localCleanup != nil else {
                throw LocalLLMError.runtimeUnavailable("This host has no downloaded-model cleanup adapter.")
            }
            var options = settings.postProcessing ?? .init()
            options.mode = enabled ? mode : .disabled
            options.modelIdentifier = model
            if let includeLexiconDirectives { options.includeLexiconDirectives = includeLexiconDirectives }
            if let includeContextTags { options.includeContextTags = includeContextTags }
            if mode == .remote || mode == .localLLM {
                options.customPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
                if mode == .remote { options.lastRemoteModelIdentifier = model }
            }
            let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if mode == .remote, !typed.isEmpty {
                try await savePostProcessingKey(typed, for: model)
                guard !closed else { return }
            }
            var changed = settings
            changed.postProcessing = options
            if let configuration = changed.configuration {
                changed.configuration = try DesktopPostProcessingConfiguration.removingMirrors(from: configuration)
            }
            changed.livePolishApproved = try retainedLivePolishApproval(after: changed)
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
            let enabledStatus: String
            switch mode {
            case .local: enabledStatus = DesktopPostProcessing.localRulesNotice
            case .localLLM: enabledStatus = "Local post-processing enabled. Transcripts stay on this computer."
            case .remote, .disabled:
                enabledStatus = "Remote post-processing enabled. Transcripts will be sent to OpenRouter."
            }
            update(enabled ? enabledStatus : "Post-processing disabled.")
        } catch { update("Could not save post-processing settings: \(error.localizedDescription)") }
    }

    private func savePostProcessingKey(_ key: String, for model: String) async throws {
        let identifier = try postProcessingCredential(for: model)
        if let saveByHand = cloudSync.saveKeyByHand {
            try await saveByHand(key, identifier)
            guard !closed else { return }
        } else {
            try Platform.saveAPIKey(key, name: identifier)
        }
        await refreshComparison()
    }

    func postProcess(
        _ original: DesktopRecordingStore.Record, options: DesktopPostProcessing.Options
    ) async -> DesktopRecordingStore.Record {
        await postProcess(original, options: options, inputText: nil)
    }

    func postProcess(
        _ original: DesktopRecordingStore.Record, options: DesktopPostProcessing.Options, inputText: String?
    ) async -> DesktopRecordingStore.Record {
        var record = original
        guard let result = record.result else { return record }
        if TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(result.text) {
            record.processedText = ""
            return record
        }
        guard !closed, !cancellationRequested, options.mode != .disabled else { return record }
        let input = inputText ?? record.correctedText ?? result.text
        let context = options.lexiconContext(
            directives: record.lexiconDirectives ?? [], tags: record.lexiconContextTags ?? []
        )
        do {
            guard DesktopPostProcessing.mode(for: options.modelIdentifier) == options.mode else {
                throw DesktopPostProcessingError.unsupportedModel
            }
            let key = options.mode == .remote
                ? try Platform.apiKey(name: postProcessingCredential(for: options.modelIdentifier)) : ""
            update("Polishing transcript… The original is saved in History.", state: 2)
            hud(record.id, .postProcessing)
            let effects = effects
            let localCleanup = localCleanup
            let task = Task {
                try Task.checkCancellation()
                let outcome: DesktopPostProcessing.Outcome
                if options.mode == .localLLM {
                    outcome = try await DesktopPostProcessing.process(
                        rawText: input, options: options, apiKey: "", lexiconDirectives: context.directives,
                        lexiconContextTags: context.tags, localLLM: localCleanup
                    )
                } else {
                    outcome = try await effects.postProcess(
                        text: input, options: options, key: key, directives: context.directives, tags: context.tags
                    )
                }
                try Task.checkCancellation()
                return outcome
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
