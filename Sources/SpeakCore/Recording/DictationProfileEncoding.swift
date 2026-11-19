import Foundation

extension DictationProfile {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(matchers, forKey: .matchers)
        try container.encodeIfPresent(transcriptionModelID, forKey: .transcriptionModelID)
        try container.encodeIfPresent(
            transcriptionRouting?.rawValue ?? unsupportedTranscriptionRouting, forKey: .transcriptionRouting
        )
        try container.encodeIfPresent(polishEnabled, forKey: .polishEnabled)
        try container.encodeIfPresent(polishModelID, forKey: .polishModelID)
        try container.encodeIfPresent(polishPrompt, forKey: .polishPrompt)
        try container.encodeIfPresent(polishOutputLanguage, forKey: .polishOutputLanguage)
        try container.encodeIfPresent(polishIncludeLexiconDirectives, forKey: .polishIncludeLexiconDirectives)
        try container.encodeIfPresent(polishIncludeContextTags, forKey: .polishIncludeContextTags)
        try container.encodeIfPresent(languageIdentifier, forKey: .languageIdentifier)
    }
}
