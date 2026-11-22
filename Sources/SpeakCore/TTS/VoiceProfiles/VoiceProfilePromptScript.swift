import Foundation

/// A short prompted script designed to capture a balanced ~15 second reference clip.
public struct VoiceProfilePromptScript: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let language: String
    public let estimatedDurationSeconds: Int
    public let sentences: [String]

    public init(
        id: String,
        title: String,
        language: String = "en",
        estimatedDurationSeconds: Int = 15,
        sentences: [String]
    ) {
        self.id = id
        self.title = title
        self.language = language
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.sentences = sentences
    }

    public var fullText: String {
        sentences.joined(separator: " ")
    }
}

/// Curated ~15-second prompt scripts covering varied consonants, vowels and natural pacing.
public enum VoiceProfilePromptCatalog {
    public static let scripts: [VoiceProfilePromptScript] = [
        VoiceProfilePromptScript(
            id: "everyday-balanced",
            title: "Everyday Balanced (~15s)",
            language: "en",
            estimatedDurationSeconds: 15,
            sentences: [
                "Good morning, let's check today's notes before the meeting begins.",
                "Bright sunshine warmed the quiet harbour while small boats drifted past the stone pier.",
                "Could you please send the revised draft by Thursday afternoon?"
            ]
        ),
        VoiceProfilePromptScript(
            id: "warm-narrative",
            title: "Warm Narrative (~15s)",
            language: "en",
            estimatedDurationSeconds: 15,
            sentences: [
                "When I read long articles aloud, a steady rhythm makes complex ideas effortless to follow.",
                "Fresh rain tapped gently on the glass roof as kettle steam curled into the cool air.",
                "Take a brief pause here, then finish reading this final sentence clearly."
            ]
        ),
        VoiceProfilePromptScript(
            id: "clear-articulation",
            title: "Clear Articulation & Numbers (~15s)",
            language: "en",
            estimatedDurationSeconds: 15,
            sentences: [
                "Flight seven forty-two departs Gate twelve at eight fifteen sharp.",
                "Jack quickly verified sixty-five zip archives, azure charts, and crisp audio waveforms.",
                "Zero shortcuts matter more than clear, natural speech."
            ]
        )
    ]

    public static func defaultScript(for language: String = "en") -> VoiceProfilePromptScript {
        let base = language.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? "en"
        return scripts.first { $0.language == base } ?? scripts[0]
    }
}
