import Foundation

/// Scalar dictation defaults shared by Apple and portable preference stores.
public enum SpeechDefaults {
    public static let temperature = 0.2
    public static let outputLanguage = "English"
    public static let liveStopGracePeriod = 0.0
    public static let recordingTailDuration = 0.5
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
public struct DesktopConfiguration: Codable, Equatable, Sendable {
    public enum Kind: Sendable {
        case text
        case boolean
        case number(ClosedRange<Double>)
        case choice([Choice])
    }

    public struct Choice: Sendable {
        public let value: String
        public let title: String
        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    public struct Field: Sendable {
        public let key: String
        public let title: String
        public let group: String
        public let kind: Kind
        public let defaultValue: AnyCodable
        public internal(set) var requiresHUDOverlay = false

        public var serializedChoices: String? {
            guard case .choice(let choices) = kind else { return nil }
            return choices.map { "\($0.value)\t\($0.title)" }.joined(separator: "\n")
        }
    }

    public static let fields: [Field] = [
        .init(key: ApplicationPreferenceKey.preferredLocale.rawValue,
              title: "Spoken language (automatic or locale, e.g. en_GB)",
              group: "Transcription", kind: .text, defaultValue: AnyCodable(.string("automatic"))),
        .init(key: ApplicationPreferenceKey.transcriptionKeywords.rawValue,
              title: "Shared keywords (comma-separated; supported providers only)",
              group: "Transcription", kind: .text, defaultValue: AnyCodable(.string(""))),
        .init(key: ApplicationPreferenceKey.assemblyAIKeyterms.rawValue,
              title: "AssemblyAI keyterms (same shared keyword list)",
              group: "Transcription", kind: .text, defaultValue: AnyCodable(.string(""))),
        .init(key: ApplicationPreferenceKey.liveStopGracePeriod.rawValue,
              title: "Live stop grace (seconds; AssemblyAI and Cartesia)",
              group: "Transcription", kind: .number(0...2),
              defaultValue: AnyCodable(.double(SpeechDefaults.liveStopGracePeriod))),
        .init(key: ApplicationPreferenceKey.postProcessingTemperature.rawValue, title: "Temperature (0 to 1)",
              group: "Post-processing", kind: .number(0...1),
              defaultValue: AnyCodable(.double(SpeechDefaults.temperature))),
        .init(key: ApplicationPreferenceKey.postProcessingOutputLanguage.rawValue,
              title: "Output language (blank keeps the transcript language)",
              group: "Post-processing", kind: .text,
              defaultValue: AnyCodable(.string(SpeechDefaults.outputLanguage))),
        .init(key: ApplicationPreferenceKey.holdThreshold.rawValue, title: "Hold threshold (seconds)",
              group: "Keyboard", kind: .number(0.2...1.5),
              defaultValue: AnyCodable(.double(HotKeyGestureTiming.defaultHoldThreshold))),
        .init(key: ApplicationPreferenceKey.doubleTapWindow.rawValue, title: "Double-tap window (seconds)",
              group: "Keyboard", kind: .number(0.2...1),
              defaultValue: AnyCodable(.double(HotKeyGestureTiming.defaultDoubleTapWindow))),
        .init(key: ApplicationPreferenceKey.showHUD.rawValue, title: "Show recording HUD",
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(SpeechDefaults.showHUD))),
        .init(key: ApplicationPreferenceKey.showLiveTranscriptInHUD.rawValue, title: "Show live transcript in HUD",
              group: "General", kind: .boolean,
              defaultValue: AnyCodable(.bool(SpeechDefaults.liveTranscriptHUD)), requiresHUDOverlay: true),
        .init(key: ApplicationPreferenceKey.shortenErrorDisplay.rawValue,
              title: "Shorten HUD error display (3.6 seconds instead of 6)",
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(SpeechDefaults.shortErrors)),
              requiresHUDOverlay: true),
        .init(key: ApplicationPreferenceKey.showCompactHUD.rawValue,
              title: "Show compact HUD (dot, level meter and timer)",
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(SpeechDefaults.compactHUD)),
              requiresHUDOverlay: true),
        .init(key: ApplicationPreferenceKey.postRecordingTailDuration.rawValue,
              title: "Recording buffer (seconds after finishing)",
              group: "Transcription", kind: .number(0...2),
              defaultValue: AnyCodable(.double(SpeechDefaults.recordingTailDuration))),
        .init(key: ApplicationPreferenceKey.hudSizePreference.rawValue, title: "Full HUD size",
              group: "General", kind: .choice(HUDExpansionPreference.allCases.map {
                  Choice(value: $0.rawValue, title: $0.displayName)
              }), defaultValue: AnyCodable(.string(HUDExpansionPreference.defaultValue.rawValue)),
              requiresHUDOverlay: true),
        .init(key: ApplicationPreferenceKey.recordingSoundsEnabled.rawValue,
              title: "Play recording start and stop sounds",
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(RecordingFeedbackDefaults.enabled))),
        .init(key: ApplicationPreferenceKey.recordingSoundProfile.rawValue, title: "Recording sound profile",
              group: "General", kind: .choice(RecordingFeedbackProfile.allCases.map {
                  Choice(value: $0.rawValue, title: $0.displayName)
              }), defaultValue: AnyCodable(.string(RecordingFeedbackDefaults.profile.rawValue))),
        .init(key: ApplicationPreferenceKey.recordingSoundVolume.rawValue, title: "Recording sound volume (0 to 1)",
              group: "General", kind: .number(0...1),
              defaultValue: AnyCodable(.double(RecordingFeedbackDefaults.volume)))
    ]

    public private(set) var values: [String: AnyCodable]

    public init(values: [String: AnyCodable] = [:]) throws {
        try Self.validateFields(in: values)
        self.values = try Self.reconciledKeywords(in: values)
    }

    private static func validateFields(in values: [String: AnyCodable]) throws {
        for field in Self.fields {
            guard let value = values[field.key] else { continue }
            let valid: Bool
            switch (field.kind, value.storage) {
            case (.text, .string(let text)):
                valid = text.utf8.count <= 65_535 && !text.contains("\0")
            case (.choice(let choices), .string(let text)):
                valid = choices.contains { $0.value == text }
            case (.boolean, .bool): valid = true
            case (.number(let range), .double(let number)): valid = number.isFinite && range.contains(number)
            case (.number(let range), .int(let number)): valid = range.contains(Double(number))
            default: valid = false
            }
            guard valid else { throw DesktopConfigurationError.invalidField(field.title) }
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
        let changed = values.merging(try Self.parsedEntries(entries)) { _, edited in edited }
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

    public var hudExpansion: HUDExpansionPreference {
        guard let preference = HUDExpansionPreference(rawValue: text("hudSizePreference")) else {
            preconditionFailure("Invalid validated HUD expansion preference.")
        }
        return preference
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
