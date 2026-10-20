import Foundation

public enum LivePolishPreference {
    public static let fields: [DesktopConfiguration.Field] = [
        .init(key: ApplicationPreferenceKey.speedMode.rawValue,
              title: "Processing speed (Auto-Clean sends text to the cleanup model)",
              group: "Transcription", kind: .choice(SpeedModeID.allCases.map {
                  .init(value: $0.rawValue, title: $0.displayName)
              }), defaultValue: AnyCodable(.string(SpeedModeID.instant.rawValue))),
        .init(key: ApplicationPreferenceKey.livePolishModel.rawValue,
              title: "Auto-Clean model ID (blank uses profile/post-processing model)",
              group: "Transcription", kind: .text, defaultValue: AnyCodable(.string(""))),
        .init(key: ApplicationPreferenceKey.livePolishDebounceMs.rawValue,
              title: "Auto-Clean debounce (whole milliseconds)",
              group: "Transcription", kind: .number(0...60_000),
              defaultValue: AnyCodable(.double(Double(LivePolishPolicy.debounceMilliseconds)))),
        .init(key: ApplicationPreferenceKey.livePolishMinDeltaChars.rawValue,
              title: "Auto-Clean minimum added characters (edits and retractions always refresh)",
              group: "Transcription", kind: .number(0...65_535),
              defaultValue: AnyCodable(.double(Double(LivePolishPolicy.minimumDeltaCharacters)))),
        .init(key: ApplicationPreferenceKey.skipPostProcessingWithLivePolish.rawValue,
              title: "Skip ordinary post-processing only after successful Auto-Clean",
              group: "Transcription", kind: .boolean,
              defaultValue: AnyCodable(.bool(LivePolishPolicy.skipPostProcessing)))
    ]
    public static let keys = Set(fields.map(\.key))
}

extension DesktopConfiguration {
    public var livePolishPreferences: LivePolishPreferences {
        get throws {
            guard let mode = SpeedModeID(rawValue: text("speedMode")) else {
                throw LivePolishError.invalidConfiguration
            }
            let debounce = number("livePolishDebounceMs")
            let delta = number("livePolishMinDeltaChars")
            guard debounce.rounded() == debounce, delta.rounded() == delta else {
                throw LivePolishError.invalidConfiguration
            }
            return LivePolishPreferences(
                mode: mode, model: text("livePolishModel"), debounceMilliseconds: Int(debounce),
                minimumDeltaCharacters: Int(delta),
                skipPostProcessing: enabled("skipPostProcessingWithLivePolish")
            )
        }
    }
}
