import Foundation
import SpeakCore
import SpeakDesktop

package enum DesktopConfigurationSaveIntent: Equatable, Sendable {
    case apply, persistOnly
}

extension DesktopHostController {
    package func configuration() throws -> DesktopConfiguration {
        var values = settings.configuration?.values ?? [:]
        values.removeValue(forKey: DesktopConnectionPreWarming.approvalProjectionKey)
        values[DesktopPostProcessingConfiguration.streamingKey] = AnyCodable(
            .bool((settings.postProcessing ?? .init()).streamingEnabled)
        )
        if let polish = settings.postProcessing {
            values["postProcessingTemperature"] = AnyCodable(.double(polish.temperature))
            values["postProcessingOutputLanguage"] = AnyCodable(.string(polish.outputLanguage ?? ""))
        }
        return try DesktopAppSwitchOutput.project(
            Platform.appSwitchPolicy(settings.textOutput), over: DesktopConfiguration(values: values)
        )
    }

    package func configurationForNativeEditor() throws -> DesktopConfiguration {
        let configuration = try configuration()
        let projected = try Platform.exportVoiceConfiguration(settings.voiceOutput, over: configuration)
        var values = configuration.values
        for key in SonioxVoicePreference.keys { values[key] = projected.values[key] }
        values[VoiceAudioFormat.preferenceKey] = projected.values[VoiceAudioFormat.preferenceKey]
        let qualityKey = VoiceSynthesisPreference.quality.key.rawValue
        values[qualityKey] = projected.values[qualityKey]
        values[DesktopConnectionPreWarming.approvalProjectionKey] = AnyCodable(.bool(connectionWarmApproved))
        if values[qualityKey] == nil, let voice = settings.voiceOutput as? DesktopVoiceOutputSettings {
            values[qualityKey] = AnyCodable(.string(voice.qualityForNativeEditor))
        }
        let storedRegion = try SonioxVoicePreference.string(SonioxVoicePreference.regionKey, in: values)
        if let region = SonioxTTSRegion.recognized(from: storedRegion) {
            values[SonioxVoicePreference.regionKey] = AnyCodable(.string(region.rawValue))
        }
        return try DesktopAppSwitchOutput.project(
            Platform.appSwitchPolicy(settings.textOutput), over: DesktopConfiguration(values: values), editor: true
        )
    }

    package func saveConfiguration(_ entries: [String]) async throws {
        try await saveConfiguration(entries, intent: .apply)
    }

    package func saveConfiguration(_ entries: [String], intent: DesktopConfigurationSaveIntent) async throws {
        guard !closed, !busy, recording == nil else {
            throw DesktopHostError(message: "Finish dictation before changing configuration.")
        }
        let previous = try configurationForNativeEditor()
        let configuration = try await reconcilingPronunciationSelection(previous.applying(entries), from: previous)
        try await persistConfiguration(
            configuration, intent: intent, status: "Configuration saved. New recordings use these preferences."
        )
    }

    package func previewRecordingFeedback(
        _ sound: RecordingFeedbackSound, configurationEntries: [String]
    ) async throws {
        try await saveConfiguration(configurationEntries, intent: .persistOnly)
        try previewRecordingFeedback(sound)
    }

    package func recoverConfigurationKeywords(_ entries: [String], selected: String) async throws {
        guard !closed, !busy, recording == nil else {
            throw DesktopHostError(message: "Finish dictation before recovering keywords.")
        }
        let previous = try configurationForNativeEditor()
        let recovered = try await reconcilingPronunciationSelection(
            previous.applying(entries).recoveringKeywords(selected), from: previous
        )
        try await persistConfiguration(
            recovered, intent: .persistOnly, status: "Recovered keywords restored. New recordings use this shared list."
        )
    }

    private func reconcilingPronunciationSelection(
        _ configuration: DesktopConfiguration, from previous: DesktopConfiguration
    ) async throws -> DesktopConfiguration {
        guard DesktopHostModels.provider(for: settings.model)?.id == "assemblyai" else { return configuration }
        guard configuration.text("transcriptionKeywords") != previous.text("transcriptionKeywords")
            || configuration.text("assemblyAIKeyterms") != previous.text("assemblyAIKeyterms") else { return configuration }
        let model = settings.model
        let hints = try await recognitionVocabulary()
        guard !closed, !busy, recording == nil, settings.model == model, try configurationForNativeEditor() == previous else {
            throw DesktopHostError(message: "Preferences changed while loading pronunciation hints. Refresh and try again.")
        }
        return try configuration.recordingPronunciationKeytermSelection(from: previous, modern: hints.pronunciationWords)
    }

    private func persistConfiguration(
        _ configuration: DesktopConfiguration, intent: DesktopConfigurationSaveIntent, status: String
    ) async throws {
        invalidateConnectionPreWarming(resetCapture: true)
        let approved = configuration.enabled(DesktopConnectionPreWarming.approvalProjectionKey)
            && configuration.enabled(DesktopConnectionPreWarming.preferenceKey)
            && (intent == .apply || connectionWarmApproved)
        let configuration = try DesktopConnectionPreWarming.removingApproval(from: configuration)
        var changed = settings
        var voice = changed.voiceOutput
        changed.configuration = try importingAutomationPreferences(
            Platform.importVoiceConfiguration(from: configuration, into: &voice)
        )
        applyingAutomationRevocation(to: &changed)
        changed.voiceOutput = voice
        changed.configuration = try Platform.importingAppSwitchPolicy(
            from: changed.configuration ?? configuration, into: &changed.textOutput
        )
        var polish = changed.postProcessing ?? .init()
        polish.temperature = configuration.number("postProcessingTemperature")
        polish.outputLanguage = configuration.text("postProcessingOutputLanguage")
        polish.streamingEnabled = configuration.enabled(DesktopPostProcessingConfiguration.streamingKey)
        changed.postProcessing = polish
        if let stored = changed.configuration {
            changed.configuration = try DesktopConfiguration(values: stored.values.filter {
                $0.key != DesktopPostProcessingConfiguration.streamingKey
            })
        }
        switch intent {
        case .apply:
            changed.livePolishApproved = configuration.text("speedMode") == SpeedModeID.livePolish.rawValue
        case .persistOnly:
            changed.livePolishApproved = try retainedLivePolishApproval(after: changed)
        }
        let previousVoice = settings.voiceOutput
        try await persistAutomationAwareSettings(changed)
        connectionWarmApproved = approved
        reconcileSonioxRegionChange(previousVoice)
        reconcileVoiceQualityChange(previousVoice)
        let cleanup = await disarmHandsFreeForConfiguration()
        try await configureRecordingFeedback(configuration)
        Platform.hud(.hidden)
        let approval = intent == .persistOnly && changed.livePolishApproved != true
            && configuration.text("speedMode") == SpeedModeID.livePolish.rawValue
            ? " Auto-Clean is not authorized; use Apply preferences to enable cleanup requests." : ""
        let preparation = connectionWarmApproved
            ? " Connection preparation approved until exit, after successful capture only; not live or streaming."
            : configuration.enabled(DesktopConnectionPreWarming.preferenceKey)
                ? " Connection preparation intent retained; approve probes on this device for this session to enable it."
                : ""
        update(status + approval + preparation + cleanup)
    }

    // Permission follows the effective cleanup route, not unrelated sound settings
    // or the ordinary post-processing prompt/temperature that Auto-Clean does not use.
    func retainedLivePolishApproval(after changed: Settings) throws -> Bool {
        guard settings.livePolishApproved == true,
              let before = settings.configuration, let after = changed.configuration,
              before.text("speedMode") == SpeedModeID.livePolish.rawValue,
              after.text("speedMode") == SpeedModeID.livePolish.rawValue else { return false }
        return try livePolishApprovalSelection(before, options: settings.postProcessing)
            == livePolishApprovalSelection(after, options: changed.postProcessing)
    }

    private func livePolishApprovalSelection(
        _ configuration: DesktopConfiguration, options: DesktopPostProcessing.Options?
    ) throws -> LivePolishPreferences {
        let preferences = try configuration.livePolishPreferences
        return LivePolishPreferences(
            mode: preferences.mode,
            model: LivePolishPolicy.model(
                configured: preferences.model,
                postProcessing: options?.modelIdentifier ?? DesktopPostProcessing.Options().modelIdentifier
            ),
            debounceMilliseconds: preferences.debounceMilliseconds,
            minimumDeltaCharacters: preferences.minimumDeltaCharacters,
            skipPostProcessing: preferences.skipPostProcessing
        )
    }

    /// Export portable preferences, never keys, device paths or native hotkeys.
    /// Retained cloud enable/model values do not grant permission to use them.
    package func exportConfiguration(path: String) throws {
        guard !closed else { throw DesktopHostError(message: "The app is closing.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let voice = try Platform.exportVoiceConfiguration(settings.voiceOutput, over: configuration())
        let projected = try DesktopPostProcessingConfiguration.exportOptions(settings.postProcessing, over: voice)
        var values = projected.values
        values.removeValue(forKey: "automationLocalConsent")
        values.removeValue(forKey: "automationEnabled")
        values.removeValue(forKey: DesktopConnectionPreWarming.approvalProjectionKey)
        let preferences = try DesktopConfiguration(values: values)
        let document = DesktopConfigurationDocument(preferences: preferences)
        let data = try encoder.encode(document)
        guard data.count <= DesktopConfigurationDocument.maximumBytes else { throw DesktopConfigurationError.tooLarge }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        update("Portable preferences exported, including preserved imported values. Credential stores were not read.")
    }

    package func importConfiguration(path: String) async throws {
        guard !closed else { throw DesktopHostError(message: "The app is closing.") }
        let document = try readConfigurationDocument(path: path)
        if busy || recording != nil || (automationUsesLocalConsent && dictationSessionID != nil) {
            if automationUsesLocalConsent,
               document.preferences.values["enableAutomationServer"]?.storage == .bool(false) {
                try await persistAutomationAwareSettings(automationSettings(enabled: false))
                throw DesktopHostError(
                    message: "Automation access revoked. Finish dictation before importing the remaining configuration."
                )
            }
            throw DesktopHostError(message: "Finish dictation before importing configuration.")
        }
        let changed = try prepareConfigurationImport(document)
        invalidateConnectionPreWarming(resetCapture: true)
        let previousVoice = settings.voiceOutput
        try await persistAutomationAwareSettings(changed)
        connectionWarmApproved = false
        reconcileSonioxRegionChange(previousVoice)
        reconcileVoiceQualityChange(previousVoice)
        let cleanup = await disarmHandsFreeForConfiguration()
        try await configureRecordingFeedback(document.preferences)
        Platform.hud(.hidden)
        update(configurationImportStatus(document, settings: changed) + cleanup)
    }

    private func readConfigurationDocument(path: String) throws -> DesktopConfigurationDocument {
        let source = URL(fileURLWithPath: path)
        let maximumBytes = DesktopConfigurationDocument.maximumBytes
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
            throw DesktopConfigurationError.tooLarge
        }
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        var data = Data()
        while data.count <= maximumBytes {
            guard let chunk = try file.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw DesktopConfigurationError.tooLarge }
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: data)
        guard document.version == 1 else { throw DesktopConfigurationError.unsupportedVersion }
        return document
    }

    private func prepareConfigurationImport(_ document: DesktopConfigurationDocument) throws -> Settings {
        var changed = settings
        var voice = changed.voiceOutput
        changed.configuration = try importingAutomationPreferences(
            Platform.importVoiceConfiguration(
                from: DesktopConnectionPreWarming.removingApproval(from: document.preferences), into: &voice
            )
        )
        applyingAutomationRevocation(to: &changed)
        changed.voiceOutput = voice
        changed.configuration = try Platform.importingAppSwitchPolicy(
            from: changed.configuration ?? document.preferences, into: &changed.textOutput
        )
        if !LivePolishPreference.keys.isDisjoint(with: document.preferences.values.keys) {
            changed.livePolishApproved = false
        }
        changed.configuration = try DesktopPostProcessingConfiguration.importOptions(
            from: changed.configuration ?? document.preferences, into: &changed.postProcessing
        )
        if document.preferences.values["postProcessingTemperature"] != nil
            || document.preferences.values["postProcessingOutputLanguage"] != nil {
            var polish = changed.postProcessing ?? .init()
            if document.preferences.values["postProcessingTemperature"] != nil {
                polish.temperature = document.preferences.number("postProcessingTemperature")
            }
            if document.preferences.values["postProcessingOutputLanguage"] != nil {
                polish.outputLanguage = document.preferences.text("postProcessingOutputLanguage")
            }
            changed.postProcessing = polish
        }
        return changed
    }

    private func configurationImportStatus(
        _ document: DesktopConfigurationDocument, settings changed: Settings
    ) -> String {
        let supported = DesktopConfiguration.supportedKeys.union(Platform.voiceConfigurationKeys)
        let unknown = (changed.configuration?.values.keys ?? document.preferences.values.keys)
            .filter { !supported.contains($0) }.sorted()
        let hasSynthesis = !DesktopConfiguration.voiceSynthesisTransferKeys
            .isDisjoint(with: document.preferences.values.keys)
        let localRules = changed.postProcessing?.modelIdentifier == LocalPostProcessingModel.builtInRulesModelID
        let status: String
        if localRules {
            status = "Configuration imported. Built-in Local Cleanup follows the imported enable choice; "
                + "no credentials accessed."
        } else if !VoiceSelectionPreference.keys.intersection(Platform.voiceConfigurationKeys)
            .isDisjoint(with: document.preferences.values.keys) {
            status = "Configuration imported. Voice selection is stored; unavailable choices refuse speech. "
                + "Choose an executable voice in Voice Output or explicitly refresh its account inventory. "
                + "No service permission was granted."
        } else if document.preferences.values[VoiceSynthesisPreference.quality.key.rawValue] != nil {
            status = "Configuration imported. Voice quality selects the compatible provider model or PCM rate. "
                + "Unknown choices are preserved; no service permission was granted."
        } else if hasSynthesis {
            status = "Configuration imported. Voice controls require a compatible provider; service choices unchanged."
        } else {
            status = "Configuration imported. Provider/model choices and service permissions are unchanged."
        }

        let autoClean = document.preferences.text("speedMode") == SpeedModeID.livePolish.rawValue
            ? " Auto-Clean is retained but not authorized: review and Apply preferences to allow cleanup requests."
            : ""
        let preparation = document.preferences.values[DesktopConnectionPreWarming.preferenceKey] != nil
            ? " Connection preparation intent retained without session approval. "
                + "Approve on this device, then complete a successful capture; live/streaming warming is unavailable."
            : ""
        return status + autoClean + preparation + automationImportNotice()
            + (unknown.isEmpty ? "" : " Preserved but not applied: \(unknown.joined(separator: ", ")).")
    }

    private func reconcileVoiceQualityChange(_ previous: Platform.VoiceOutputSettings?) {
        let oldVoice = previous as? DesktopVoiceOutputSettings
        let newVoice = settings.voiceOutput as? DesktopVoiceOutputSettings
        if oldVoice != newVoice { voiceSettingsRevision &+= 1 }
        if oldVoice?.quality != newVoice?.quality || oldVoice?.modelID != newVoice?.modelID
            || oldVoice?.voiceID != newVoice?.voiceID
            || oldVoice?.strictVoiceSelection != newVoice?.strictVoiceSelection {
            voiceCredentialEpoch = UUID()
        }
    }

    private func disarmHandsFreeForConfiguration() async -> String {
        guard handsFreeMachine.isArmed else { return "" }
        let failure = await disarmHandsFree(status: "Hands-free disarmed after configuration changed.")
        return failure.map { " Hands-free cleanup failed: \($0)" } ?? ""
    }
}

package struct DesktopConfigurationDocument: Codable {
    package static let maximumBytes = 1_048_576
    package var version = 1
    package let preferences: DesktopConfiguration
}
