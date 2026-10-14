import SpeakCore

package struct DesktopHostNativePreferenceProjection: Sendable {
    package var values: [String: AnyCodable] = [:]
    package var suppressedKeys: Set<String> = []
    package var notices: [DataMigrationPreferenceProjection.Notice] = []

    package init() {}

    package mutating func set(_ key: ApplicationPreferenceKey, _ value: AnyCodable.JSONValue) {
        values[key.rawValue] = AnyCodable(value)
    }

    package mutating func nativeOnly(_ path: String, suppressing key: ApplicationPreferenceKey? = nil) {
        notices.append(.init(path: path, reason: .nativeOnly))
        if let key { suppressedKeys.insert(key.rawValue) }
    }

    package mutating func activation(_ style: String) {
        guard let activation = HotKeyActivationStyle(rawValue: style),
              HotKeyActivationStyle.macOSStyles.contains(activation) else {
            nativeOnly("hotKey.style", suppressing: .hotKeyActivation)
            return
        }
        set(.hotKeyActivation, .string(style))
    }

    package mutating func voice(_ voice: DesktopVoiceOutputSettings?) {
        guard let voice else { return }
        if let value = voice.autoPlay { set(.ttsAutoPlay, .bool(value)) }
        if let value = voice.saveToRecordings { set(.ttsSaveToDirectory, .bool(value)) }
        if let value = voice.speed { set(.ttsSpeed, .double(value)) }
        if let value = voice.pitch { set(.ttsPitch, .double(value)) }
        if let value = voice.useSSML { set(.ttsUseSSML, .bool(value)) }
        if let value = voice.favoriteVoices {
            values[VoiceFavoritePreference.key] = VoiceFavoritePreference.encoded(value)
        }
        if let value = voice.sonioxRegion { set(.sonioxTTSRegion, .string(value)) }
        if let value = voice.language { set(.ttsLanguage, .string(value)) }
        if let value = voice.quality { set(.ttsQuality, .string(value)) }
        if let value = voice.format { set(.ttsOutputFormat, .string(value)) }
        if voice.modelID != nil { nativeOnly("voiceOutput.modelID") }
        if voice.voiceID != nil { nativeOnly("voiceOutput.voiceID") }
        if voice.strictVoiceSelection != nil { nativeOnly("voiceOutput.strictVoiceSelection") }
        if voice.trackUsage != nil { nativeOnly("voiceOutput.ttsTrackUsage") }
    }

    package mutating func appSwitchDelivery(_ policy: AppSwitchDelivery?) {
        if let policy { set(.appSwitchDelivery, .string(policy.rawValue)) }
    }
}

extension DesktopHostPlatform {
    package static func archiveNativePreferences(
        textOutput: TextOutputOptions?, hotKey: HotKeySettings?, voiceOutput: VoiceOutputSettings?
    ) -> DesktopHostNativePreferenceProjection {
        var projection = DesktopHostNativePreferenceProjection()
        if textOutput != nil { projection.nativeOnly("textOutput") }
        if hotKey != nil { projection.nativeOnly("hotKey") }
        if voiceOutput != nil { projection.nativeOnly("voiceOutput") }
        return projection
    }
}
