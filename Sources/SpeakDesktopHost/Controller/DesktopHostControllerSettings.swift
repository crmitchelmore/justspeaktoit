import Foundation
import SpeakCore
import SpeakDesktop

// Persisted host settings: typed values plus preserved unknown keys and the
// archive bookkeeping that keeps a round trip lossless.

extension DesktopHostController {
    package struct SettingsValues: Codable, Sendable {
        package var model = ModelCatalog.defaultBatchTranscriptionModel
        package var postProcessing: DesktopPostProcessing.Options?
        package var microphoneDeviceID: String?
        package var batchModel: String?
        package var liveModel: String?
        // Absent keys keep the native smart insert-at-cursor default.
        package var textOutput: Platform.TextOutputOptions?
        package var hotKey: Platform.HotKeySettings?
        package var voiceOutput: Platform.VoiceOutputSettings?
        package var automationEnabled: Bool?
        /// Device-local approval, never included in portable configuration.
        package var automationLocalConsent: Bool?
        package var localModel: String?
        /// Last on-device live model (`local/streaming/whisperkit/...`).
        package var localLiveModel: String?
        package var localUseGPU: Bool?
        /// Device-local Azure resource, under the Apple apps' key.
        package var azureSpeechResourceEndpoint: String?
        package var appearance: DesktopAppearance?
        /// Last reached registration for hosts that cannot read it back.
        package var runAtLogin: Bool?
        package var configuration: DesktopConfiguration?
        /// Device-local approval; portable imports cannot grant service access.
        package var livePolishApproved: Bool?
    }

    @dynamicMemberLookup
    package struct Settings: Codable, Sendable {
        private var values = SettingsValues()
        private var preserved: [String: AnyCodable] = [:]
        var archiveModelKeys: Set<String> = []
        var nativeSourceRoots: [String: AnyCodable] = [:]
        package var archiveUnknownKeys: Set<String> { Set(preserved.keys) }
        package init() {}

        package subscript<Value>(dynamicMember keyPath: WritableKeyPath<SettingsValues, Value>) -> Value {
            get { values[keyPath: keyPath] }
            set {
                values[keyPath: keyPath] = newValue
                noteArchiveWrite(keyPath)
            }
        }

        // swiftlint:disable:next function_body_length
        package init(from decoder: Decoder) throws {
            values = try SettingsValues(from: decoder)
            let container = try decoder.singleValueContainer()
            let all = try container.decode([String: AnyCodable].self)
            captureArchivePresence(all)
            try adoptStoredStreamingPreference(all)
            var configuration = values.configuration?.values ?? [:]
            let warmKey = DesktopConnectionPreWarming.preferenceKey
            if configuration[warmKey] == nil { configuration[warmKey] = all[warmKey] }
            configuration = configuration.filter { !DesktopConfiguration.editorProjectionKeys.contains($0.key) }
            if values.configuration != nil || configuration[warmKey] != nil {
                values.configuration = try DesktopConfiguration(values: configuration)
            }
            let known: Set<String> = DesktopConfiguration.editorProjectionKeys.union([
                "model", "postProcessing", "microphoneDeviceID", "batchModel", "liveModel", "textOutput",
                "hotKey", "voiceOutput", "automationEnabled", "automationLocalConsent", "localModel", "localUseGPU",
                "azureSpeechResourceEndpoint", "appearance", "runAtLogin", "configuration", "livePolishApproved",
                "localLiveModel",
                DesktopConnectionPreWarming.preferenceKey
            ])
            preserved = all.filter { !known.contains($0.key) }
            try adoptStoredPreferences(DesktopConfiguration.pronunciationPreferenceKeys)
            try adoptStoredPreferences(DesktopConfiguration.modulatePreferenceKeys)
            let voiceKeys = VoiceSelectionPreference.keys.intersection(Platform.voiceConfigurationKeys)
            if !voiceKeys.isDisjoint(with: preserved.keys)
                || !voiceKeys.isDisjoint(with: (values.configuration?.values ?? [:]).keys) {
                var configuration = values.configuration?.values ?? [:]
                let claimed = voiceKeys.union(
                    [VoiceSynthesisPreference.quality.key.rawValue].filter {
                        Platform.voiceConfigurationKeys.contains($0)
                    })
                for key in claimed {
                    if configuration[key] == nil { configuration[key] = preserved[key] }
                    preserved.removeValue(forKey: key)
                }
                values.configuration = try DesktopConfiguration(values: configuration)
            }
            guard Platform.self is any DesktopHostAutomationPlatform.Type else { return }
            let key = ApplicationPreferenceKey.enableAutomationServer.rawValue
            preserved.removeValue(forKey: key)
            if let canonical = values.configuration?.values[key] {
                guard case .bool = canonical.storage else {
                    throw DesktopConfigurationError.invalidField("Automation")
                }
            }
            let desired = all[key] ?? values.automationEnabled.map { AnyCodable(.bool($0)) }
            if values.configuration?.values[key] == nil, let desired {
                guard case .bool = desired.storage else {
                    throw DesktopConfigurationError.invalidField("Automation")
                }
                var configuration = values.configuration?.values ?? [:]
                configuration[key] = desired
                values.configuration = try DesktopConfiguration(values: configuration)
            }
        }

        private mutating func adoptStoredPreferences(_ keys: Set<String>) throws {
            guard !keys.isDisjoint(with: preserved.keys) else { return }
            var configuration = values.configuration?.values ?? [:]
            for key in keys {
                if configuration[key] == nil { configuration[key] = preserved[key] }
                preserved.removeValue(forKey: key)
            }
            values.configuration = try DesktopConfiguration(values: configuration)
        }

        private mutating func adoptStoredStreamingPreference(_ all: [String: AnyCodable]) throws {
            let key = DesktopPostProcessingConfiguration.streamingKey
            guard let configuration = values.configuration, let legacy = configuration.values[key] else { return }
            let explicit: Bool
            if case .object(let stored)? = all["postProcessing"]?.storage {
                explicit = stored["streamingEnabled"] != nil
            } else { explicit = false }
            if !explicit {
                _ = try DesktopPostProcessingConfiguration.importOptions(
                    from: DesktopConfiguration(values: [key: legacy]), into: &values.postProcessing
                )
            }
            values.configuration = try DesktopConfiguration(values: configuration.values.filter { $0.key != key })
        }

        package func encode(to encoder: Encoder) throws {
            let known = try JSONDecoder().decode(
                [String: AnyCodable].self, from: JSONEncoder().encode(values)
            )
            var container = encoder.singleValueContainer()
            try container.encode(preserved.merging(known) { _, current in current })
        }
    }
}
