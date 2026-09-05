import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Providers currently supported by the iOS OpenClaw voice-output route.
public enum VoiceOutputProvider: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case deepgram
    case soniox

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepgram: "Deepgram"
        case .soniox: "Soniox"
        }
    }

    public var apiKeyIdentifier: String {
        switch self {
        case .deepgram: "deepgram.apiKey"
        case .soniox: "soniox.apiKey"
        }
    }

    public var speedRange: ClosedRange<Double> {
        switch self {
        case .deepgram: 0.5...2.0
        case .soniox: SonioxTTSAPI.speedRange
        }
    }

    public static func inferred(modelID: String?, voiceID: String?) -> VoiceOutputProvider {
        if modelID?.lowercased().hasPrefix("tts-rt-") == true
            || voiceID?.lowercased().hasPrefix("soniox/") == true {
            return .soniox
        }
        return .deepgram
    }
}

public struct VoiceOutputLanguageOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Voice-output language preferences are intentionally independent from speech recognition.
public enum VoiceOutputLanguageCatalog {
    public static let automaticIdentifier = "automatic"

    public static let options: [VoiceOutputLanguageOption] = TranscriptionLanguageCatalog.options.map {
        VoiceOutputLanguageOption(id: $0.id, displayName: $0.displayName)
    }

    public static func normalizedIdentifier(_ identifier: String?) -> String {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return automaticIdentifier
        }
        return identifier
    }

    /// Resolves Automatic from the content language first, then the device locale.
    public static func languageCode(
        for identifier: String?,
        content: String,
        deviceLocaleIdentifier: String = Locale.current.identifier
    ) -> String {
        let normalized = normalizedIdentifier(identifier)
        if normalized != automaticIdentifier {
            return baseLanguageCode(normalized) ?? baseLanguageCode(deviceLocaleIdentifier) ?? "en"
        }

        return detectedLanguageCode(in: content)
            ?? baseLanguageCode(deviceLocaleIdentifier)
            ?? "en"
    }

    /// Pure resolver used by contract tests and callers with their own language detector.
    public static func automaticLanguageCode(
        contentLanguageCode: String?,
        deviceLocaleIdentifier: String
    ) -> String {
        baseLanguageCode(contentLanguageCode)
            ?? baseLanguageCode(deviceLocaleIdentifier)
            ?? "en"
    }

    private static func detectedLanguageCode(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        #if canImport(NaturalLanguage)
        return NLLanguageRecognizer.dominantLanguage(for: trimmed).flatMap {
            baseLanguageCode($0.rawValue)
        }
        #else
        return nil
        #endif
    }

    private static func baseLanguageCode(_ identifier: String?) -> String? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty,
              identifier.lowercased() != automaticIdentifier,
              identifier.lowercased() != "und" else {
            return nil
        }
        return identifier
            .lowercased()
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .first
            .map(String.init)
    }
}
