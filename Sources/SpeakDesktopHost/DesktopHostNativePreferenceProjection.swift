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
        if voice.modelID != nil { nativeOnly("voiceOutput.modelID") }
        if voice.voiceID != nil { nativeOnly("voiceOutput.voiceID") }
        if voice.trackUsage != nil { nativeOnly("voiceOutput.ttsTrackUsage") }
    }
}

extension DesktopHostPlatform {
    package static var nativeConfigurationPlatform: DesktopNativeConfigurationCapture.Platform? { nil }

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
