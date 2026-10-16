import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    package func configuration() throws -> DesktopConfiguration {
        var values = settings.configuration?.values ?? [:]
        if let polish = settings.postProcessing {
            values["postProcessingTemperature"] = AnyCodable(.double(polish.temperature))
            values["postProcessingOutputLanguage"] = AnyCodable(.string(polish.outputLanguage ?? ""))
        }
        return try DesktopConfiguration(values: values)
    }

    package func configurationForNativeEditor() throws -> DesktopConfiguration {
        let configuration = try configuration()
        let projected = try Platform.exportVoiceConfiguration(settings.voiceOutput, over: configuration)
        var values = configuration.values
        for key in SonioxVoicePreference.keys { values[key] = projected.values[key] }
        let storedRegion = try SonioxVoicePreference.string(SonioxVoicePreference.regionKey, in: values)
        if let region = SonioxTTSRegion.recognized(from: storedRegion) {
            values[SonioxVoicePreference.regionKey] = AnyCodable(.string(region.rawValue))
        }
        return try DesktopConfiguration(values: values)
    }

    package func saveConfiguration(_ entries: [String]) async throws {
        guard !closed, !busy, recording == nil else {
            throw DesktopHostError(message: "Finish dictation before changing configuration.")
        }
        let configuration = try configurationForNativeEditor().applying(entries)
        try await persistConfiguration(
            configuration, status: "Configuration saved. New recordings use these preferences."
        )
    }

    package func recoverConfigurationKeywords(_ entries: [String], selected: String) async throws {
        guard !closed, !busy, recording == nil else {
            throw DesktopHostError(message: "Finish dictation before recovering keywords.")
        }
        let recovered = try configurationForNativeEditor().applying(entries).recoveringKeywords(selected)
        try await persistConfiguration(
            recovered, status: "Recovered keywords restored. New recordings use this shared list."
        )
    }

    private func persistConfiguration(_ configuration: DesktopConfiguration, status: String) async throws {
        var changed = settings
        var voice = changed.voiceOutput
        changed.configuration = try Platform.importVoiceConfiguration(from: configuration, into: &voice)
        changed.voiceOutput = voice
        var polish = changed.postProcessing ?? .init()
        polish.temperature = configuration.number("postProcessingTemperature")
        polish.outputLanguage = configuration.text("postProcessingOutputLanguage")
        changed.postProcessing = polish
        try effects.writeSettings(JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json"))
        let previousVoice = settings.voiceOutput
        settings = changed
        reconcileSonioxRegionChange(previousVoice)
        let cleanup = await disarmHandsFreeForConfiguration()
        try await configureRecordingFeedback(configuration)
        Platform.hud(.hidden)
        update(status + cleanup)
    }

    /// Export portable preferences, never keys, device paths or native hotkeys.
    /// Retained cloud enable/model values do not grant permission to use them.
    package func exportConfiguration(path: String) throws {
        guard !closed else { throw DesktopHostError(message: "The app is closing.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let voice = try Platform.exportVoiceConfiguration(settings.voiceOutput, over: configuration())
        let preferences = try DesktopPostProcessingConfiguration.exportOptions(settings.postProcessing, over: voice)
        let document = DesktopConfigurationDocument(preferences: preferences)
        let data = try encoder.encode(document)
        guard data.count <= DesktopConfigurationDocument.maximumBytes else { throw DesktopConfigurationError.tooLarge }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        update("Portable preferences exported, including preserved imported values. Credential stores were not read.")
    }

    package func importConfiguration(path: String) async throws {
        guard !closed, !busy, recording == nil else {
            throw DesktopHostError(message: "Finish dictation before importing configuration.")
        }
        let document = try readConfigurationDocument(path: path)
        let changed = try prepareConfigurationImport(document)
        try effects.writeSettings(JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json"))
        let previousVoice = settings.voiceOutput
        settings = changed
        reconcileSonioxRegionChange(previousVoice)
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
        changed.configuration = try Platform.importVoiceConfiguration(from: document.preferences, into: &voice)
        changed.voiceOutput = voice
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
        } else if hasSynthesis {
            status = "Configuration imported. Voice controls require a compatible provider; service choices unchanged."
        } else {
            status = "Configuration imported. Provider/model choices and service permissions are unchanged."
        }
        return status + (unknown.isEmpty ? "" : " Preserved but not applied: \(unknown.joined(separator: ", ")).")
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
