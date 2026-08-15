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

    /// Upper bound on the audio payload a file-transcription intent will
    /// stage. Well above every provider's own upload limit (OpenRouter caps
    /// inline audio at 50 MB) but low enough that a spoofed or accidental
    /// multi-gigabyte file fails fast instead of stalling or killing the app.
    public static let maximumAudioFileBytes = 500 * 1024 * 1024

    public enum AudioFileValidationError: LocalizedError, Equatable {
        case missingExtension(filename: String)
        case unsupportedType(fileExtension: String)
        case fileTooLarge(byteCount: Int, limit: Int)

        public var errorDescription: String? {
            switch self {
            case .missingExtension(let filename):
                return "\"\(filename)\" has no file extension, so the audio format can't be determined."
            case .unsupportedType(let fileExtension):
                let supported = AutomationIntentSupport.supportedAudioExtensions.sorted()
                    .joined(separator: ", ")
                return "\".\(fileExtension)\" files aren't supported. Supported formats: \(supported)."
            case .fileTooLarge(let byteCount, let limit):
                let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
                let cap = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
                return "The audio file is \(size), which is over the \(cap) limit for file transcription."
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

    /// Rejects audio payloads over `maximumAudioFileBytes` before any bytes
    /// are staged to disk or handed to a provider.
    public static func validateAudioFileSize(_ byteCount: Int) throws {
        guard byteCount <= maximumAudioFileBytes else {
            throw AudioFileValidationError.fileTooLarge(
                byteCount: byteCount,
                limit: maximumAudioFileBytes
            )
        }
    }

    // MARK: - Polish prompt mapping

    /// The system prompt / user message pair sent to the LLM by Polish Text.
    public struct PolishRequest: Equatable {
        public let systemPrompt: String
        public let userMessage: String
        /// Whether the user supplied their own prompt, replacing the cleanup
        /// contract. Local execution paths need this to know they must honour
        /// the prompt pair verbatim instead of rebuilding the stock cleanup
        /// payload (or to fail clearly when they cannot follow a prompt).
        public let isCustomPrompt: Bool

        public init(systemPrompt: String, userMessage: String, isCustomPrompt: Bool) {
            self.systemPrompt = systemPrompt
            self.userMessage = userMessage
            self.isCustomPrompt = isCustomPrompt
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
                userMessage: TranscriptCleanupPolicy.userMessage(transcript: text),
                isCustomPrompt: false
            )
        }
        return PolishRequest(systemPrompt: trimmedPrompt, userMessage: text, isCustomPrompt: true)
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
