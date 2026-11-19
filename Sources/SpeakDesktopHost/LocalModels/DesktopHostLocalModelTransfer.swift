import SpeakCore
import SpeakDesktop

/// Portable choices are not permission to change the active recording route.
package enum DesktopHostLocalModelTransfer {
    static let batchKey = ApplicationPreferenceKey.localTranscriptionModel.rawValue
    static let liveKey = ApplicationPreferenceKey.localStreamingModelSource.rawValue
    static let modeKey = ApplicationPreferenceKey.localTranscriptionMode.rawValue
    static let keys: Set<String> = [batchKey, liveKey]

    static func importing<Platform: DesktopHostPlatform>(
        _ configuration: DesktopConfiguration, into settings: inout DesktopHostController<Platform>.Settings
    ) throws -> DesktopConfiguration {
        var values = configuration.values
        let entries = DesktopHostModels.snapshot.entries
        for (key, live) in [(batchKey, false), (liveKey, true)] {
            guard let value = values[key] else { continue }
            guard case .string(let identifier) = value.storage else {
                throw DesktopConfigurationError.invalidField("Local model choice")
            }
            guard entries.contains(where: {
                $0.option.id == identifier && $0.isAvailable && $0.isLocal && $0.isLive == live
            }) else { continue }
            let activeLocal = DesktopHostModels.isLocal(settings.model)
            let activeLive = DesktopHostModels.isLocalLive(settings.model)
            guard !activeLocal || activeLive != live || settings.model == identifier else { continue }
            if live { settings.localLiveModel = identifier } else { settings.localModel = identifier }
            values.removeValue(forKey: key)
        }
        return try DesktopConfiguration(values: values)
    }

    static func project<Platform: DesktopHostPlatform>(
        _ settings: DesktopHostController<Platform>.Settings, over configuration: DesktopConfiguration
    ) throws -> DesktopConfiguration {
        var values = configuration.values
        for (key, identifier) in [(batchKey, settings.localModel), (liveKey, settings.localLiveModel)] {
            if values[key] == nil, let identifier { values[key] = AnyCodable(.string(identifier)) }
        }
        if DesktopHostModels.isLocal(settings.model), values[modeKey] == nil {
            values[modeKey] = AnyCodable(.string(DesktopHostModels.isLocalLive(settings.model) ? "streaming" : "batch"))
        }
        return try DesktopConfiguration(values: values)
    }

    static func removingChoice(
        _ key: String, from configuration: DesktopConfiguration?
    ) throws -> DesktopConfiguration? {
        guard let configuration else { return nil }
        return try DesktopConfiguration(values: configuration.values.filter { $0.key != key && $0.key != modeKey })
    }

    static func removingMirrors<Platform: DesktopHostPlatform>(
        _ configuration: DesktopConfiguration, settings: DesktopHostController<Platform>.Settings
    ) throws -> DesktopConfiguration {
        var values = configuration.values
        for (key, identifier) in [(batchKey, settings.localModel), (liveKey, settings.localLiveModel)] {
            if let identifier, values[key]?.storage == .string(identifier) { values.removeValue(forKey: key) }
        }
        if DesktopHostModels.isLocal(settings.model) {
            let mode = DesktopHostModels.isLocalLive(settings.model) ? "streaming" : "batch"
            if values[modeKey]?.storage == .string(mode) { values.removeValue(forKey: modeKey) }
        }
        return try DesktopConfiguration(values: values)
    }
}

extension DesktopHostController {
    func publishImportedLocalChoices(from previous: Settings) throws {
        guard settings.localModel != previous.localModel || settings.localLiveModel != previous.localLiveModel else {
            return
        }
        do {
            try Platform.publishLocalModelPreferences(batch: settings.localModel, live: settings.localLiveModel)
        } catch {
            throw DesktopHostError(
                message: "Configuration saved, but model choices could not be refreshed. "
                    + "Reopen the app before switching Local modes. \(error.localizedDescription)"
            )
        }
    }

    func localModelImportNotice(_ document: DesktopConfigurationDocument, settings changed: Settings) -> String {
        let present = DesktopHostLocalModelTransfer.keys.intersection(document.preferences.values.keys)
        guard !present.isEmpty else { return "" }
        let applied = present.filter { changed.configuration?.values[$0] == nil }
        let saved = applied.isEmpty ? "" : " Supported Local model choices saved."
        return saved + " Active model unchanged; no model was downloaded or activated. "
            + "Unavailable choices or changes to the active mode are preserved, not applied; use Models to choose."
    }
}
