import Foundation

/// Scalar dictation defaults shared by Apple and portable preference stores.
public enum SpeechDefaults {
    public static let temperature = 0.2
    public static let outputLanguage = "English"
    public static let postProcessingIncludeLexiconDirectives = true
    public static let postProcessingIncludeContextTags = true
    public static let postProcessingStreamingEnabled = true
    public static let connectionPreWarmingEnabled = true
    /// Pre-streaming desktop documents and API calls retain their completed-only behavior.
    public static let desktopLegacyPostProcessingStreamingEnabled = false // swiftlint:disable:this identifier_name
    public static let liveStopGracePeriod = 0.0
    public static let recordingTailDuration = 0.5
    public static let voiceCommandsEnabled = true
    public static let cancelRecordingOnEscape = true
    /// Keep a cancelled recording's audio in History so it can be transcribed later.
    /// On by default: cancelling (often by accident, with Escape) should never lose speech.
    public static let keepAudioOnCancel = true
    public static let clipboardInsertionTriggers = ""
    public static let showHUD = true
    public static let liveTranscriptHUD = true
    public static let shortErrors = false
    public static let compactHUD = false
    public static let successHUDDuration = 2.4
    public static let failureHUDDuration = 6.0
    public static let shortFailureHUDDuration = 3.6
}

/// Portable preferences use the Mac's keys. Unknown entries survive edits and
/// exports, but are never treated as implemented capabilities.
/// The field catalogue lives in DesktopConfiguration+Fields.swift.
public struct DesktopConfiguration: Codable, Equatable, Sendable {
    public private(set) var values: [String: AnyCodable]

    public var visualDensity: AppVisualDensity {
        guard let density = AppVisualDensity(rawValue: text(ApplicationPreferenceKey.visualDensity.rawValue)) else {
            preconditionFailure("Validated layout density is invalid.")
        }
        return density
    }

    public init(values: [String: AnyCodable] = [:]) throws {
        var values = values
        let graceKey = ApplicationPreferenceKey.liveStopGracePeriod.rawValue
        if values[graceKey] == nil,
           let legacy = values[ApplicationPreferenceKey.deepgramStopGracePeriod.rawValue] {
            values[graceKey] = legacy
        }
        try Self.validateFields(in: values)
        try Self.validatePronunciationPreferences(in: values)
        // JSON decodes whole numbers as Int; native numeric entries use Double.
        for field in Self.fields {
            guard case .number = field.kind, let value = values[field.key],
                  case .int(let number) = value.storage else { continue }
            values[field.key] = AnyCodable(.double(Double(number)))
        }
        self.values = try Self.reconciledKeywords(in: values)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func validateFields(in values: [String: AnyCodable]) throws {
        for field in Self.fields {
            guard let value = values[field.key] else { continue }
            let valid: Bool
            switch (field.kind, value.storage) {
            case (.text, .string(let text)):
                valid = text.utf8.count <= 65_535 && !text.contains("\0")
            case (.choice(let choices), .string(let text)):
                valid = !Self.modulatePreferenceKeys.contains(field.key) && (choices.contains { $0.value == text }
                    || ((field.key == SonioxVoicePreference.regionKey
                            || field.key == VoiceSynthesisPreference.quality.key.rawValue
                            || field.key == VoiceAudioFormat.preferenceKey
                            || field.key == ApplicationPreferenceKey.speedMode.rawValue)
                        && text.utf8.count <= 256
                        && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })))
            case (.choice, .bool): valid = Self.modulatePreferenceKeys.contains(field.key)
            case (.boolean, .bool): valid = true
            case (.number(let range), .double(let number)): valid = number.isFinite && range.contains(number)
            case (.number(let range), .int(let number)): valid = range.contains(Double(number))
            default: valid = false
            }
            guard valid else { throw DesktopConfigurationError.invalidField(field.title) }
            if field.key == ApplicationPreferenceKey.livePolishDebounceMs.rawValue
                || field.key == ApplicationPreferenceKey.livePolishMinDeltaChars.rawValue
                || field.key == ApplicationPreferenceKey.autoCorrectionsPromotionThreshold.rawValue,
               case .double(let number) = value.storage, number.rounded() != number {
                throw DesktopConfigurationError.invalidField(field.title)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        try self.init(values: decoder.singleValueContainer().decode([String: AnyCodable].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public func value(for field: Field) -> AnyCodable { values[field.key] ?? field.defaultValue }

    public var entries: [String] {
        Self.fields.map { field in
            switch value(for: field).storage {
            case .string(let text): return text
            case .bool(let enabled): return enabled ? "1" : "0"
            case .double(let number): return String(number)
            case .int(let number): return String(number)
            default: preconditionFailure("Validated field has the wrong type.")
            }
        }
    }

    /// Checks editor scalars without guessing the saved keyword reconciliation history.
    public static func validateEntries(_ entries: [String]) throws {
        try validateFields(in: parsedEntries(entries))
    }

    private static func parsedEntries(_ entries: [String]) throws -> [String: AnyCodable] {
        guard entries.count == Self.fields.count else { throw DesktopConfigurationError.invalidField("Field count") }
        var changed: [String: AnyCodable] = [:]
        for (field, entry) in zip(Self.fields, entries) {
            switch field.kind {
            case .choice where Self.modulatePreferenceKeys.contains(field.key):
                guard entry == "" || entry == "0" || entry == "1" else {
                    throw DesktopConfigurationError.invalidField(field.title)
                }
                if !entry.isEmpty { changed[field.key] = AnyCodable(.bool(entry == "1")) }
            case .text, .choice: changed[field.key] = AnyCodable(.string(entry))
            case .boolean:
                guard entry == "0" || entry == "1" else {
                    throw DesktopConfigurationError.invalidField(field.title)
                }
                changed[field.key] = AnyCodable(.bool(entry == "1"))
            case .number:
                guard let number = Double(entry), number.isFinite else {
                    throw DesktopConfigurationError.invalidField(field.title)
                }
                changed[field.key] = AnyCodable(.double(number))
            }
        }
        return changed
    }

    public func applying(_ entries: [String]) throws -> Self {
        var changed = values.merging(try Self.parsedEntries(entries)) { _, edited in edited }
        for (field, entry) in zip(Self.fields, entries)
            where Self.modulatePreferenceKeys.contains(field.key) && entry.isEmpty {
            changed.removeValue(forKey: field.key)
        }
        return try Self(values: changed).recordingPronunciationKeytermSelection(from: self)
    }

    private func stored(_ key: String) -> AnyCodable.JSONValue {
        guard let field = Self.fields.first(where: { $0.key == key }) else {
            preconditionFailure("Missing canonical field.")
        }
        return value(for: field).storage
    }

    public func text(_ key: String) -> String {
        guard case .string(let value) = stored(key) else { preconditionFailure("Not a text preference.") }
        return value
    }

    public func enabled(_ key: String) -> Bool {
        guard case .bool(let value) = stored(key) else { preconditionFailure("Not a boolean preference.") }
        return value
    }

    public func number(_ key: String) -> Double {
        switch stored(key) {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: preconditionFailure("Not a numeric preference.")
        }
    }

    public var language: String? {
        TranscriptionLanguageCatalog.providerLanguage(for: text("preferredLocale"))
    }

    public var hudExpansion: HUDExpansionPreference {
        guard let preference = HUDExpansionPreference(rawValue: text("hudSizePreference")) else {
            preconditionFailure("Invalid validated HUD expansion preference.")
        }
        return preference
    }

    public var liveOptions: LiveClientOptions {
        LiveClientOptions(
            keywords: TranscriptionKeywordPolicy.words(from: text("transcriptionKeywords")),
            assemblyAIKeyterms: pronunciationKeyterms(
                addingTo: TranscriptionKeywordPolicy.words(from: text("assemblyAIKeyterms"))
            ),
            modulate: modulateLiveOptions, postStopFinalizeBudget: nil, stopGracePeriod: number("liveStopGracePeriod")
        ).capturingPronunciationKeyterms(pronunciationKeytermSelection)
    }
}

public enum DesktopConfigurationError: LocalizedError {
    case invalidField(String)
    case tooLarge
    case unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .invalidField(let field): return "Invalid \(field). Check the value and its allowed range."
        case .tooLarge: return "Configuration files must be regular files no larger than 1 MB."
        case .unsupportedVersion: return "This configuration version cannot be imported by this build."
        }
    }
}
