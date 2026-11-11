import Foundation

extension DesktopConfiguration {
    public static var modulatePreferenceKeys: Set<String> {
        [
            ApplicationPreferenceKey.modulateSpeakerDiarization.rawValue,
            ApplicationPreferenceKey.modulateEmotionSignal.rawValue,
            ApplicationPreferenceKey.modulateAccentSignal.rawValue,
            ApplicationPreferenceKey.modulatePIIPhiTagging.rawValue
        ]
    }

    static var modulateFields: [Field] {
        [
            modulateField(.modulateSpeakerDiarization, title: "Identify speakers (Modulate)",
                          legacy: "Legacy defaults (batch on; live off)"),
            modulateField(.modulateEmotionSignal, title: "Detect emotion (Modulate)", legacy: "Default (off)"),
            modulateField(.modulateAccentSignal, title: "Detect accents (Modulate)", legacy: "Default (off)"),
            modulateField(.modulatePIIPhiTagging, title: "Tag personal and health information (Modulate)",
                          legacy: "Default (off)")
        ]
    }

    private static func modulateField(_ key: ApplicationPreferenceKey, title: String, legacy: String) -> Field {
        .init(key: key.rawValue, title: title, group: "Transcription",
              kind: .choice([.init(value: "", title: legacy), .init(value: "1", title: "Enabled"),
                             .init(value: "0", title: "Disabled")]),
              defaultValue: AnyCodable(.string("")))
    }

    public var modulateLiveOptions: ModulateLiveOptions {
        let defaults = ModulateLiveOptions.none
        return ModulateLiveOptions(
            speakerDiarization: modulateValue(.modulateSpeakerDiarization, default: defaults.speakerDiarization),
            emotionSignal: modulateValue(.modulateEmotionSignal, default: defaults.emotionSignal),
            accentSignal: modulateValue(.modulateAccentSignal, default: defaults.accentSignal),
            piiPhiTagging: modulateValue(.modulatePIIPhiTagging, default: defaults.piiPhiTagging)
        )
    }

    public var modulateBatchFeatures: ModulateTranscriptionFeatures {
        let defaults = ModulateTranscriptionFeatures()
        return ModulateTranscriptionFeatures(
            speakerDiarization: modulateValue(.modulateSpeakerDiarization, default: defaults.speakerDiarization),
            emotionSignal: modulateValue(.modulateEmotionSignal, default: defaults.emotionSignal),
            accentSignal: modulateValue(.modulateAccentSignal, default: defaults.accentSignal),
            piiPhiTagging: modulateValue(.modulatePIIPhiTagging, default: defaults.piiPhiTagging)
        )
    }

    private func modulateValue(_ key: ApplicationPreferenceKey, default fallback: Bool) -> Bool {
        guard let value = values[key.rawValue] else { return fallback }
        guard case .bool(let enabled) = value.storage else {
            preconditionFailure("Invalid validated Modulate feature preference.")
        }
        return enabled
    }
}
