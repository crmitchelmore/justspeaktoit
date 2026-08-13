import Foundation

/// Pure helpers shared by the App Intents (Shortcuts) automation surface on
/// macOS and iOS. Kept in SpeakCore so parameter mapping and validation stay
/// unit-testable without AppIntents or UI dependencies — the intents themselves
/// are thin wrappers over these functions and the platform managers.
public enum AutomationIntentSupport {
    // MARK: - Audio file validation

    /// Audio container extensions the Transcribe Audio File intent accepts.
    /// The union of formats the batch providers can ingest; the provider still
    /// has the final say and reports its own error for an unsupported codec.
    public static let supportedAudioExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "flac", "m4a", "mp3", "mp4", "ogg", "opus", "wav", "webm"
    ]

    public enum AudioFileValidationError: LocalizedError, Equatable {
        case missingExtension(filename: String)
        case unsupportedType(fileExtension: String)

        public var errorDescription: String? {
            switch self {
            case .missingExtension(let filename):
                return "\"\(filename)\" has no file extension, so the audio format can't be determined."
            case .unsupportedType(let fileExtension):
                let supported = AutomationIntentSupport.supportedAudioExtensions.sorted()
                    .joined(separator: ", ")
                return "\".\(fileExtension)\" files aren't supported. Supported formats: \(supported)."
            }
        }
    }

    /// Validates an audio filename for file transcription and returns its
    /// normalized (lowercased) extension, used to name the temporary copy so
    /// providers can detect the container format.
    public static func validatedAudioExtension(forFilename filename: String) throws -> String {
        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard !fileExtension.isEmpty else {
            throw AudioFileValidationError.missingExtension(filename: filename)
        }
        guard supportedAudioExtensions.contains(fileExtension) else {
            throw AudioFileValidationError.unsupportedType(fileExtension: fileExtension)
        }
        return fileExtension
    }

    // MARK: - Polish prompt mapping

    /// The system prompt / user message pair sent to the LLM by Polish Text.
    public struct PolishRequest: Equatable {
        public let systemPrompt: String
        public let userMessage: String

        public init(systemPrompt: String, userMessage: String) {
            self.systemPrompt = systemPrompt
            self.userMessage = userMessage
        }
    }

    /// Maps the Polish Text intent parameters onto an LLM request.
    ///
    /// Without a custom prompt this is the shared transcript-cleanup contract:
    /// the caller's effective post-processing prompt — which already folds in
    /// the user's custom base prompt, output language, and profile override —
    /// plus the JSON-wrapped transcript payload. With a custom prompt the user
    /// is deliberately overriding that contract, so their prompt becomes the
    /// system prompt and the text is passed through verbatim — wrapping it in
    /// the cleanup payload would fight instructions like "summarise this".
    ///
    /// `defaultSystemPrompt` is injected rather than derived here so the intent
    /// honours whatever the platform's post-processing manager would use for a
    /// normal dictation session.
    public static func polishRequest(
        text: String,
        customPrompt: String?,
        defaultSystemPrompt: String
    ) -> PolishRequest {
        let trimmedPrompt = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedPrompt.isEmpty else {
            return PolishRequest(
                systemPrompt: defaultSystemPrompt,
                userMessage: TranscriptCleanupPolicy.userMessage(transcript: text)
            )
        }
        return PolishRequest(systemPrompt: trimmedPrompt, userMessage: text)
    }

    // MARK: - Transcript selection

    /// Picks the text Get Last Transcription should return for a history
    /// entry: the polished transcript when present and non-blank, else the raw
    /// one, else nil so the caller can skip the entry entirely.
    public static func bestTranscript(raw: String?, polished: String?) -> String? {
        for candidate in [polished, raw] {
            if let candidate,
               !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return nil
    }
}
