import Foundation
import SpeakCore
import SpeakDesktop

extension WindowsAppController {
    func postProcessingOptions() -> DesktopPostProcessing.Options { settings.postProcessing ?? .init() }

    /// The Local choices in the dialog: built-in rules, then every language
    /// model the host projects (catalogue, then imports).
    var localPostProcessingChoices: [WindowsLocalPostProcessingChoice] {
        let installer = localInstaller
        let rules = DesktopLocalPostProcessing.builtInRulesOption
        let models = DesktopLocalPostProcessing.models(host: .windows).map { model in
            let item = WindowsLocalModelEntry.language(model).item
            let state = installer.state(of: item) == .installed ? "" : " \u{2014} download in Local models"
            let size = Self.megabytes(model.artifact.byteCount)
            return WindowsLocalPostProcessingChoice(
                id: model.identifier, name: "\(model.displayName) (\(size))\(state)", usesPrompt: true
            )
        }
        let builtIn = WindowsLocalPostProcessingChoice(
            id: rules.id, name: rules.displayName + " \u{2014} built-in rules", usesPrompt: false
        )
        return [builtIn] + models
    }

    /// The options an Apply chooses, or nil for an index the dialog did not offer.
    private func postProcessingChoice(mode: Int, modelIndex: Int, prompt: String) -> DesktopPostProcessing.Options? {
        var options = postProcessingOptions()
        options.customPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
        switch mode {
        case 2:
            let choices = localPostProcessingChoices
            guard choices.indices.contains(modelIndex) else { return nil }
            options.mode = .local
            options.modelIdentifier = choices[modelIndex].id
        case 0, 1:
            guard DesktopPostProcessing.remoteModels.indices.contains(modelIndex) else { return nil }
            options.mode = mode == 1 ? .remote : .disabled
            options.modelIdentifier = DesktopPostProcessing.remoteModels[modelIndex].id
        default: return nil
        }
        return options
    }

    private func savedStatus(_ options: DesktopPostProcessing.Options) -> String {
        switch options.mode {
        case .remote: return "Remote post-processing enabled. Transcripts will be sent to OpenRouter."
        case .disabled: return "Post-processing disabled."
        case .local:
            let name = DesktopLocalPostProcessing.displayName(for: options.modelIdentifier)
            return "Local post-processing with \(name) enabled. "
                + (languageModelReadiness(options.modelIdentifier) ?? "Transcripts stay on this PC.")
        }
    }

    /// Saves the dialog's Apply. A typed key is saved first, and a blank field
    /// keeps the saved one. With iCloud sync the key goes through the same step
    /// as the Settings key field, so a deletion synced from the Mac cannot
    /// remove it; the choices are then applied to the settings as they are
    /// after that save, and not at all if the controller closed meanwhile.
    /// `mode` is 0 off, 1 remote and 2 local, as the native dialog reports.
    func savePostProcessing(mode: Int, modelIndex: Int, prompt: String, key: String) async {
        guard !closed, let options = postProcessingChoice(mode: mode, modelIndex: modelIndex, prompt: prompt) else {
            return
        }
        do {
            let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            // Local post-processing takes no key; the dialog sends none for it.
            if !typed.isEmpty, options.mode != .local {
                let identifier = try postProcessingCredential(for: options.modelIdentifier)
                if let saveByHand = cloudSync.saveKeyByHand {
                    try await saveByHand(typed, identifier)
                    guard !closed else { return }
                } else {
                    try WindowsNative.saveAPIKey(typed, name: identifier)
                }
            }
            var changed = settings
            changed.postProcessing = options
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
            update(savedStatus(options))
        } catch { update("Could not save post-processing settings: \(error.localizedDescription)") }
    }

    /// Republishes the dialog's remote and local choices, for example after an
    /// import or a download changed what Local offers.
    func configurePostProcessingControls() {
        guard let context = localModels.context else { return }
        do { try configurePostProcessingControls(context: context) } catch {
            update(error.localizedDescription)
        }
    }

    func configurePostProcessingControls(context: UnsafeMutableRawPointer) throws {
        let options = postProcessingOptions()
        let choices = localPostProcessingChoices
        let selected = choices.firstIndex { $0.id == options.modelIdentifier.lowercased() } ?? 0
        try WindowsNative.configurePostProcessing(
            options, local: choices.map { ($0.name, $0.usesPrompt) }, localSelected: selected, context: context
        )
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
        guard !closed, !cancellationRequested, options.mode != .disabled else { return record }
        do {
            let outcome: DesktopPostProcessing.Outcome
            if options.mode == .local {
                let text = result.text
                let task = Task { try await self.processLocally(text, options: options) }
                postProcessingTask = task
                defer { postProcessingTask = nil }
                outcome = try await task.value
            } else {
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
                outcome = try await task.value
            }
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

/// One Local entry in the post-processing dialog.
struct WindowsLocalPostProcessingChoice: Sendable {
    let id: String
    let name: String
    let usesPrompt: Bool
}
