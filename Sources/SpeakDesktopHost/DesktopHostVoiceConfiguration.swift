import SpeakCore

extension DesktopVoiceOutputSettings {
    package func configurationProjection(over values: [String: AnyCodable]) -> [String: AnyCodable] {
        var projection = values
        projection[VoiceFavoritePreference.key] = favoriteVoices.map(VoiceFavoritePreference.encoded)
            ?? projection[VoiceFavoritePreference.key]
        projection[SonioxVoicePreference.regionKey] = sonioxRegion.map { AnyCodable(.string($0)) }
            ?? projection[SonioxVoicePreference.regionKey]
        projection[SonioxVoicePreference.languageKey] = language.map { AnyCodable(.string($0)) }
            ?? projection[SonioxVoicePreference.languageKey]
        projection[VoiceGenerationPreference.autoPlay.rawValue] = AnyCodable(.bool(generationOptions.autoPlay))
        projection[VoiceGenerationPreference.saveToRecordings.rawValue] =
            AnyCodable(.bool(generationOptions.saveToRecordings))
        projection[ApplicationPreferenceKey.ttsSpeed.rawValue] =
            speed.map { AnyCodable(.double($0)) } ?? projection[ApplicationPreferenceKey.ttsSpeed.rawValue]
                ?? AnyCodable(.double(VoiceSynthesisOptions.defaultSpeed))
        projection[ApplicationPreferenceKey.ttsPitch.rawValue] =
            pitch.map { AnyCodable(.double($0)) } ?? projection[ApplicationPreferenceKey.ttsPitch.rawValue]
                ?? AnyCodable(.double(VoiceSynthesisOptions.defaultPitch))
        projection[ApplicationPreferenceKey.ttsUseSSML.rawValue] =
            useSSML.map { AnyCodable(.bool($0)) } ?? projection[ApplicationPreferenceKey.ttsUseSSML.rawValue]
                ?? AnyCodable(.bool(VoiceSynthesisOptions.defaultUseSSML))
        return projection
    }

    package mutating func applyConfigurationProjection(_ values: [String: AnyCodable]) throws {
        let play = try VoiceGenerationPreference.autoPlay.value(in: values)
        let save = try VoiceGenerationPreference.saveToRecordings.value(in: values)
        let synthesis = try VoiceSynthesisPreferenceUpdate(preferences: values)
        let favorites = try VoiceFavoritePreference.value(in: values)
        let region = try SonioxVoicePreference.string(SonioxVoicePreference.regionKey, in: values)
        let language = try SonioxVoicePreference.string(SonioxVoicePreference.languageKey, in: values)
        if let play { autoPlay = play }
        if let save { saveToRecordings = save }
        if let speed = synthesis.speed { self.speed = speed }
        if let pitch = synthesis.pitch { self.pitch = pitch }
        if let useSSML = synthesis.useSSML { self.useSSML = useSSML }
        if let favorites { favoriteVoices = favorites }
        if let region { sonioxRegion = region }
        if let language { self.language = language }
    }

    package func validatedSynthesisOptions() throws -> VoiceSynthesisOptions {
        try .init(speed: speed ?? VoiceSynthesisOptions.defaultSpeed,
                  pitch: pitch ?? VoiceSynthesisOptions.defaultPitch,
                  useSSML: useSSML ?? VoiceSynthesisOptions.defaultUseSSML)
    }

    package func languageTitle(accountInventory: VoiceAccountInventory?) -> String {
        do {
            return VoiceOutputLanguagePreference.title(for: try DesktopSpeechVoice.resolved(
                modelID: modelID, voiceID: voiceID, accountInventory: accountInventory))
        } catch {
            return VoiceOutputLanguagePreference.title(for: nil)
        }
    }
}

extension DesktopVoiceOutputSettings {
    package static func importConfiguration(
        from configuration: DesktopConfiguration, into voiceOutput: inout Self?
    ) throws -> DesktopConfiguration {
        let keys = DesktopConfiguration.voiceTransferKeys
        guard !keys.isDisjoint(with: configuration.values.keys) else { return configuration }
        var voice = voiceOutput ?? .init()
        try voice.applyConfigurationProjection(configuration.values)
        let result = try DesktopConfiguration(values: configuration.values.filter { !keys.contains($0.key) })
        voiceOutput = voice
        return result
    }

    package static func exportConfiguration(
        _ voiceOutput: Self?, over configuration: DesktopConfiguration
    ) throws -> DesktopConfiguration {
        guard let voiceOutput else { return configuration }
        return try DesktopConfiguration(values: voiceOutput.configurationProjection(over: configuration.values))
    }
}

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func voiceConfigurationEditorSnapshot() throws -> (
        preferences: DesktopConfiguration, languageTitle: String
    ) {
        let preferences = try configurationForNativeEditor()
        let saved = voiceOutputSettings()
        let inventory = voiceDiscovery.inventories.values.first {
            $0.desktopVoices.contains { $0.id == saved.voiceID && $0.modelID == saved.modelID }
        }
        return (preferences, saved.languageTitle(accountInventory: inventory))
    }
}

extension DesktopHostPlatform {
    package static var voiceConfigurationKeys: Set<String> { [] }

    package static func exportVoiceConfiguration(
        _ voiceOutput: VoiceOutputSettings?, over configuration: DesktopConfiguration
    ) throws -> DesktopConfiguration { configuration }

    package static func importVoiceConfiguration(
        from configuration: DesktopConfiguration, into voiceOutput: inout VoiceOutputSettings?
    ) throws -> DesktopConfiguration { configuration }
}
