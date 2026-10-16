import Foundation

/// The Mac preference is an ordered list of voice IDs, not provider/model pairs.
/// Unknown IDs and duplicates are transfer material; only the picker projection deduplicates them.
public enum VoiceFavoritePreference {
    public static let key = ApplicationPreferenceKey.ttsFavoriteVoices.rawValue

    public static func value(in preferences: [String: AnyCodable]) throws -> [String]? {
        guard let value = preferences[key] else { return nil }
        guard case .array(let entries) = value.storage else {
            throw DesktopConfigurationError.invalidField("Favorite voices")
        }
        return try entries.map {
            guard case .string(let identifier) = $0 else {
                throw DesktopConfigurationError.invalidField("Favorite voices")
            }
            return identifier
        }
    }

    public static func encoded(_ identifiers: [String]) -> AnyCodable {
        AnyCodable(.array(identifiers.map(AnyCodable.JSONValue.string)))
    }

    public static func updating(_ identifiers: [String], voiceID: String, favorite: Bool) -> [String] {
        if favorite { return identifiers.contains(voiceID) ? identifiers : identifiers + [voiceID] }
        return identifiers.filter { $0 != voiceID }
    }
}

extension DesktopSpeechVoice {
    /// Mac TTS favorites namespace Deepgram's otherwise unprefixed synthesis IDs.
    public var favoriteIdentifier: String {
        if case .deepgram(let voice) = self { return voice.providerVoiceID }
        return id
    }

    /// Favorites remain Mac-compatible voice IDs; an executable picker row
    /// also distinguishes OpenAI and Gemini models that share that same voice.
    public var pickerIdentifier: String {
        switch self {
        case .openai, .gemini: modelID + "|" + favoriteIdentifier
        default: favoriteIdentifier
        }
    }
}

/// One native snapshot; row identity never depends on a filtered row's position.
public struct DesktopVoicePicker: Sendable {
    public let voices: [DesktopSpeechVoice]
    public let favorites: [Bool]
    public let favoriteIndices: [Int]

    public init(voices: [DesktopSpeechVoice], favoriteIDs: [String]) {
        var seen: Set<String> = []
        let unique = voices.filter { seen.insert($0.pickerIdentifier).inserted }
        self.voices = unique
        let saved = Set(favoriteIDs)
        favorites = unique.map { saved.contains($0.favoriteIdentifier) }
        var projected: Set<String> = []
        favoriteIndices = favoriteIDs.compactMap { identifier in
            guard projected.insert(identifier).inserted else { return nil }
            return unique.firstIndex { $0.favoriteIdentifier == identifier }
        }
    }
}
