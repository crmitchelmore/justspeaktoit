import Foundation

/// Scalar dictation defaults shared by Apple and portable preference stores.
public enum SpeechDefaults {
    public static let temperature = 0.2
    public static let outputLanguage = "English"
    public static let liveStopGracePeriod = 0.0
    public static let showHUD = true
    public static let liveTranscriptHUD = true
}

/// Portable preferences use the Mac's keys. Unknown entries survive edits and
/// exports, but are never treated as implemented capabilities.
public struct DesktopConfiguration: Codable, Equatable, Sendable {
    public enum Kind: Sendable {
        case text
        case boolean
        case number(ClosedRange<Double>)
    }

    public struct Field: Sendable {
        public let key: String
        public let title: String
        public let group: String
        public let kind: Kind
        public let defaultValue: AnyCodable
    }

    public static let fields: [Field] = [
        .init(key: "preferredLocale", title: "Spoken language (automatic or locale, e.g. en_GB)",
              group: "Transcription", kind: .text, defaultValue: AnyCodable(.string("automatic"))),
        .init(key: "transcriptionKeywords", title: "Keywords (comma-separated; supported providers only)",
              group: "Transcription", kind: .text, defaultValue: AnyCodable(.string(""))),
        .init(key: "assemblyAIKeyterms", title: "AssemblyAI keyterms (comma-separated)",
              group: "Transcription", kind: .text, defaultValue: AnyCodable(.string(""))),
        .init(key: "liveStopGracePeriod", title: "Live stop grace (seconds; AssemblyAI and Cartesia)",
              group: "Transcription", kind: .number(0...2),
              defaultValue: AnyCodable(.double(SpeechDefaults.liveStopGracePeriod))),
        .init(key: "postProcessingTemperature", title: "Temperature (0 to 1)",
              group: "Post-processing", kind: .number(0...1),
              defaultValue: AnyCodable(.double(SpeechDefaults.temperature))),
        .init(key: "postProcessingOutputLanguage", title: "Output language (blank keeps the transcript language)",
              group: "Post-processing", kind: .text,
              defaultValue: AnyCodable(.string(SpeechDefaults.outputLanguage))),
        .init(key: "holdThreshold", title: "Hold threshold (seconds)",
              group: "Keyboard", kind: .number(0.2...1.5),
              defaultValue: AnyCodable(.double(HotKeyGestureTiming.defaultHoldThreshold))),
        .init(key: "doubleTapWindow", title: "Double-tap window (seconds)",
              group: "Keyboard", kind: .number(0.2...1),
              defaultValue: AnyCodable(.double(HotKeyGestureTiming.defaultDoubleTapWindow))),
        .init(key: "showHUD", title: "Show recording HUD",
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(SpeechDefaults.showHUD))),
        .init(key: "showLiveTranscriptInHUD", title: "Show live transcript in HUD",
              group: "General", kind: .boolean,
              defaultValue: AnyCodable(.bool(SpeechDefaults.liveTranscriptHUD)))
    ]

    public private(set) var values: [String: AnyCodable]

    public init(values: [String: AnyCodable] = [:]) throws {
        for field in Self.fields {
            guard let value = values[field.key] else { continue }
            let valid: Bool
            switch (field.kind, value.storage) {
            case (.text, .string(let text)):
                valid = text.utf8.count <= 65_535 && !text.contains("\0")
            case (.boolean, .bool): valid = true
            case (.number(let range), .double(let number)): valid = number.isFinite && range.contains(number)
            case (.number(let range), .int(let number)): valid = range.contains(Double(number))
            default: valid = false
            }
            guard valid else { throw DesktopConfigurationError.invalidField(field.title) }
        }
        self.values = values
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

    public func applying(_ entries: [String]) throws -> Self {
        guard entries.count == Self.fields.count else { throw DesktopConfigurationError.invalidField("Field count") }
        var changed = values
        for (field, entry) in zip(Self.fields, entries) {
            switch field.kind {
            case .text: changed[field.key] = AnyCodable(.string(entry))
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
        return try Self(values: changed)
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

    public var liveOptions: LiveClientOptions {
        LiveClientOptions(
            keywords: MetaMuseVoiceTranscribe.keywords(from: text("transcriptionKeywords")),
            assemblyAIKeyterms: text("assemblyAIKeyterms").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            modulate: .none, postStopFinalizeBudget: nil, stopGracePeriod: number("liveStopGracePeriod")
        )
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
