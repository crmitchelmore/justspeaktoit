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

    static var modulateLiveFields: [Field] {
        let defaults = ModulateLiveOptions.none
        return [
            .init(key: ApplicationPreferenceKey.modulateSpeakerDiarization.rawValue,
                  title: "Identify speakers (Modulate live only)", group: "Transcription", kind: .boolean,
                  defaultValue: AnyCodable(.bool(defaults.speakerDiarization))),
            .init(key: ApplicationPreferenceKey.modulateEmotionSignal.rawValue,
                  title: "Detect emotion (Modulate live only)", group: "Transcription", kind: .boolean,
                  defaultValue: AnyCodable(.bool(defaults.emotionSignal))),
            .init(key: ApplicationPreferenceKey.modulateAccentSignal.rawValue,
                  title: "Detect accents (Modulate live only)", group: "Transcription", kind: .boolean,
                  defaultValue: AnyCodable(.bool(defaults.accentSignal))),
            .init(key: ApplicationPreferenceKey.modulatePIIPhiTagging.rawValue,
                  title: "Tag personal and health information (Modulate live only)",
                  group: "Transcription", kind: .boolean,
                  defaultValue: AnyCodable(.bool(defaults.piiPhiTagging)))
        ]
    }

    public var modulateLiveOptions: ModulateLiveOptions {
        ModulateLiveOptions(
            speakerDiarization: enabled(ApplicationPreferenceKey.modulateSpeakerDiarization.rawValue),
            emotionSignal: enabled(ApplicationPreferenceKey.modulateEmotionSignal.rawValue),
            accentSignal: enabled(ApplicationPreferenceKey.modulateAccentSignal.rawValue),
            piiPhiTagging: enabled(ApplicationPreferenceKey.modulatePIIPhiTagging.rawValue)
        )
    }
}
