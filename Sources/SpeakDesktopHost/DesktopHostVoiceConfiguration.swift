import SpeakCore

extension DesktopVoiceOutputSettings {
    package func configurationProjection(over values: [String: AnyCodable]) -> [String: AnyCodable] {
        var projection = values
        projection[VoiceGenerationPreference.autoPlay.rawValue] = AnyCodable(.bool(generationOptions.autoPlay))
        projection[VoiceGenerationPreference.saveToRecordings.rawValue] =
            AnyCodable(.bool(generationOptions.saveToRecordings))
        return projection
    }

    package mutating func applyConfigurationProjection(_ values: [String: AnyCodable]) throws {
        if let enabled = try VoiceGenerationPreference.autoPlay.value(in: values) { autoPlay = enabled }
        if let enabled = try VoiceGenerationPreference.saveToRecordings.value(in: values) {
            saveToRecordings = enabled
        }
    }
}

extension DesktopVoiceOutputSettings {
    package static func importConfiguration(
        from configuration: DesktopConfiguration, into voiceOutput: inout Self?
    ) throws -> DesktopConfiguration {
        let keys = DesktopConfiguration.voiceGenerationTransferKeys
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
