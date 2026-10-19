import SpeakCore

/// Archive-only presence tracking: a model slot is projected only when it was
/// stored or explicitly chosen, never when catalogue preparation filled it.
extension DesktopHostController.Settings {
    package var archiveModel: String? { archiveModelKeys.contains("model") ? self.model : nil }
    package var archiveBatchModel: String? { archiveModelKeys.contains("batchModel") ? self.batchModel : nil }
    package var archiveLiveModel: String? { archiveModelKeys.contains("liveModel") ? self.liveModel : nil }
    package var archiveLocalModel: String? { archiveModelKeys.contains("localModel") ? self.localModel : nil }

    package mutating func preservingArchiveModelPresence<T>(_ update: (inout Self) throws -> T) rethrows -> T {
        let explicit = archiveModelKeys
        defer { archiveModelKeys = explicit }
        return try update(&self)
    }

    mutating func captureArchivePresence(_ all: [String: AnyCodable]) {
        let nativeRoots = Set(DesktopNativeConfigurationField.allCases.map(\.sourceRoot))
            .subtracting([DesktopNativeConfigurationField.legacyCustomPrompt.sourceRoot])
        nativeSourceRoots = all.filter { nativeRoots.contains($0.key) }
        archiveModelKeys = Set(all.keys).intersection(["model", "batchModel", "liveModel", "localModel"])
    }

    mutating func noteArchiveWrite<Value>(
        _ keyPath: WritableKeyPath<SettingsValues, Value>
    ) {
        if let root = nativeSourceRoot(for: keyPath) { nativeSourceRoots.removeValue(forKey: root) }
        if keyPath == \SettingsValues.model { archiveModelKeys.insert("model") }
        if keyPath == \SettingsValues.batchModel { archiveModelKeys.insert("batchModel") }
        if keyPath == \SettingsValues.liveModel { archiveModelKeys.insert("liveModel") }
        if keyPath == \SettingsValues.localModel { archiveModelKeys.insert("localModel") }
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
        return key.flatMap { self.configuration?.values[String($0)] }
    }

    private func currentNativeSourceRoot(_ field: DesktopNativeConfigurationField) throws -> AnyCodable? {
        switch field {
        case .customPrompt: return try self.postProcessing.map { try DataMigrationCoding.value($0) }
        case .microphoneDeviceID: return self.microphoneDeviceID.map { AnyCodable(.string($0)) }
        case .localUseGPU: return self.localUseGPU.map { AnyCodable(.bool($0)) }
        case .azureSpeechResourceEndpoint:
            return self.azureSpeechResourceEndpoint.map { AnyCodable(.string($0)) }
        case .voiceModelID, .voiceID, .voiceTrackUsage:
            return try self.voiceOutput.map { try DataMigrationCoding.value($0) }
        case .hotKey: return try self.hotKey.map { try DataMigrationCoding.value($0) }
        case .textOutput: return try self.textOutput.map { try DataMigrationCoding.value($0) }
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
