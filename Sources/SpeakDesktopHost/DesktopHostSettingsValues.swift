import Foundation
import SpeakCore
import SpeakDesktop

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
        package var localModel: String?
        package var localUseGPU: Bool?
        /// Device-local Azure resource, under the Apple apps' key.
        package var azureSpeechResourceEndpoint: String?
        package var appearance: DesktopAppearance?
        /// Last reached registration for hosts that cannot read it back.
        package var runAtLogin: Bool?
        package var configuration: DesktopConfiguration?
    }

    @dynamicMemberLookup
    package struct Settings: Codable, Sendable {
        private var values = SettingsValues()
        private var preserved: [String: AnyCodable] = [:]
        private var archiveModelKeys: Set<String> = []
        private var nativeSourceRoots: [String: AnyCodable] = [:]
        package var archiveModel: String? { archiveModelKeys.contains("model") ? values.model : nil }
        package var archiveBatchModel: String? { archiveModelKeys.contains("batchModel") ? values.batchModel : nil }
        package var archiveLiveModel: String? { archiveModelKeys.contains("liveModel") ? values.liveModel : nil }
        package var archiveLocalModel: String? { archiveModelKeys.contains("localModel") ? values.localModel : nil }
        package var archiveUnknownKeys: Set<String> { Set(preserved.keys) }
        package init() {}

        package subscript<Value>(dynamicMember keyPath: WritableKeyPath<SettingsValues, Value>) -> Value {
            get { values[keyPath: keyPath] }
            set {
                values[keyPath: keyPath] = newValue
                if let root = nativeSourceRoot(for: keyPath) { nativeSourceRoots.removeValue(forKey: root) }
                if keyPath == \SettingsValues.model { archiveModelKeys.insert("model") }
                if keyPath == \SettingsValues.batchModel { archiveModelKeys.insert("batchModel") }
                if keyPath == \SettingsValues.liveModel { archiveModelKeys.insert("liveModel") }
                if keyPath == \SettingsValues.localModel { archiveModelKeys.insert("localModel") }
            }
        }

        package mutating func preservingArchiveModelPresence<T>(_ update: (inout Self) throws -> T) rethrows -> T {
            let explicit = archiveModelKeys
            defer { archiveModelKeys = explicit }
            return try update(&self)
        }

        package init(from decoder: Decoder) throws {
            values = try SettingsValues(from: decoder)
            let container = try decoder.singleValueContainer()
            let all = try container.decode([String: AnyCodable].self)
            let nativeRoots = Set(DesktopNativeConfigurationField.allCases.map(\.sourceRoot))
                .subtracting([DesktopNativeConfigurationField.legacyCustomPrompt.sourceRoot])
            nativeSourceRoots = all.filter { nativeRoots.contains($0.key) }
            archiveModelKeys = Set(all.keys).intersection(["model", "batchModel", "liveModel", "localModel"])
            let known: Set<String> = [
                "model", "postProcessing", "microphoneDeviceID", "batchModel", "liveModel", "textOutput",
                "hotKey", "voiceOutput", "automationEnabled", "localModel", "localUseGPU",
                "azureSpeechResourceEndpoint", "appearance", "runAtLogin", "configuration"
            ]
            preserved = all.filter { !known.contains($0.key) }
        }

        package func encode(to encoder: Encoder) throws {
            let known = try JSONDecoder().decode(
                [String: AnyCodable].self, from: JSONEncoder().encode(values)
            )
            var container = encoder.singleValueContainer()
            try container.encode(preserved.merging(known) { _, current in current })
        }

        package func nativeConfigurationSources() throws -> [String: AnyCodable] {
            var roots = nativeSourceRoots
            for field in DesktopNativeConfigurationField.allCases
                where roots[field.sourceRoot] == nil && field != .legacyCustomPrompt {
                if let value = try currentNativeSourceRoot(field) { roots[field.sourceRoot] = value }
            }
            return roots
        }

        package func legacyCustomPromptSource() -> AnyCodable? {
            let key = DesktopNativeConfigurationField.legacyCustomPrompt.rawValue.split(separator: ".").last
            return key.flatMap { values.configuration?.values[String($0)] }
        }

        private func currentNativeSourceRoot(_ field: DesktopNativeConfigurationField) throws -> AnyCodable? {
            switch field {
            case .customPrompt: return try values.postProcessing.map { try DataMigrationCoding.value($0) }
            case .microphoneDeviceID: return values.microphoneDeviceID.map { AnyCodable(.string($0)) }
            case .localUseGPU: return values.localUseGPU.map { AnyCodable(.bool($0)) }
            case .azureSpeechResourceEndpoint:
                return values.azureSpeechResourceEndpoint.map { AnyCodable(.string($0)) }
            case .voiceModelID, .voiceID, .voiceTrackUsage:
                return try values.voiceOutput.map { try DataMigrationCoding.value($0) }
            case .hotKey: return try values.hotKey.map { try DataMigrationCoding.value($0) }
            case .textOutput: return try values.textOutput.map { try DataMigrationCoding.value($0) }
            case .legacyCustomPrompt: return nil
            }
        }

        private func nativeSourceRoot<Value>(for keyPath: WritableKeyPath<SettingsValues, Value>) -> String? {
            if keyPath == \SettingsValues.postProcessing {
                return DesktopNativeConfigurationField.customPrompt.sourceRoot
            }
            if keyPath == \SettingsValues.voiceOutput { return DesktopNativeConfigurationField.voiceID.sourceRoot }
            if keyPath == \SettingsValues.hotKey { return DesktopNativeConfigurationField.hotKey.sourceRoot }
            if keyPath == \SettingsValues.textOutput { return DesktopNativeConfigurationField.textOutput.sourceRoot }
            if keyPath == \SettingsValues.microphoneDeviceID {
                return DesktopNativeConfigurationField.microphoneDeviceID.sourceRoot
            }
            if keyPath == \SettingsValues.localUseGPU { return DesktopNativeConfigurationField.localUseGPU.sourceRoot }
            if keyPath == \SettingsValues.azureSpeechResourceEndpoint {
                return DesktopNativeConfigurationField.azureSpeechResourceEndpoint.sourceRoot
            }
            return nil
        }
    }
}
