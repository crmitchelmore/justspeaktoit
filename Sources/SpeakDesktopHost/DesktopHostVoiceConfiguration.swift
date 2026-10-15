import SpeakCore

extension DesktopVoiceOutputSettings {
    package func configurationProjection(over values: [String: AnyCodable]) -> [String: AnyCodable] {
        var projection = values
        projection[VoiceFavoritePreference.key] = favoriteVoices.map(VoiceFavoritePreference.encoded)
            ?? projection[VoiceFavoritePreference.key]
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
        if let play { autoPlay = play }
        if let save { saveToRecordings = save }
        if let speed = synthesis.speed { self.speed = speed }
        if let pitch = synthesis.pitch { self.pitch = pitch }
        if let useSSML = synthesis.useSSML { self.useSSML = useSSML }
        if let favorites { favoriteVoices = favorites }
    }

    package func validatedSynthesisOptions() throws -> VoiceSynthesisOptions {
        try .init(speed: speed ?? VoiceSynthesisOptions.defaultSpeed,
                  pitch: pitch ?? VoiceSynthesisOptions.defaultPitch,
                  useSSML: useSSML ?? VoiceSynthesisOptions.defaultUseSSML)
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

extension DesktopHostPlatform {
    package static var voiceConfigurationKeys: Set<String> { [] }

    package static func exportVoiceConfiguration(
        _ voiceOutput: VoiceOutputSettings?, over configuration: DesktopConfiguration
    ) throws -> DesktopConfiguration { configuration }

    package static func importVoiceConfiguration(
        from configuration: DesktopConfiguration, into voiceOutput: inout VoiceOutputSettings?
    ) throws -> DesktopConfiguration { configuration }
}
