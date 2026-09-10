import Foundation

/// Canonical identifiers and limits for Speechmatics realtime transcription.
///
/// Contract: https://docs.speechmatics.com/rt-api-ref (read 2026-09-10).
public enum SpeechmaticsRealtime {
    /// Realtime catalogue identifier.
    public static let liveCatalogID = "speechmatics/enhanced-streaming"

    /// The EU realtime endpoint. Speechmatics also serves `us.rt` and `au.rt`;
    /// the app has always used EU and changing it would move an existing user's
    /// audio to a different region, so the host stays fixed.
    static let webSocketHost = "eu.rt.speechmatics.com"
    static let webSocketPath = "/v2/"

    /// The realtime accuracy model the catalogue entry names. Speechmatics
    /// renamed this field from `operating_point` to `model`; the old name is
    /// documented as "kept for backward compatibility only", so the request
    /// sends `model`.
    public static let defaultModel = "enhanced"

    /// `AddAudio` frames are counted, and the count is what `EndOfStream`
    /// reports as `last_seq_no`. Speechmatics rejects an audio frame smaller
    /// than a hundred milliseconds of PCM, so the trailing flush is padded to
    /// this size rather than dropped.
    static let minimumChunkBytes = 3_200

    /// How long `finishAndWait()` waits for `EndOfTranscript` after
    /// `EndOfStream`. Speechmatics finalises the buffered tail in that window;
    /// the caller's own budget (`LiveModelCapabilities.postStopFinalizeBudget`)
    /// governs the surrounding stop.
    static let finishBudget: TimeInterval = 5

    /// Resolves a Speak language selection to the concrete language code
    /// Speechmatics requires. Automatic resolves to the system language: a
    /// hard-coded `en` transcribes a French speaker with the English model
    /// (issue #696).
    public static func languageCode(
        for selection: String?,
        systemLocaleIdentifier: String = Locale.current.identifier
    ) -> String {
        let resolved = TranscriptionLanguageCatalog.localeIdentifier(
            for: TranscriptionLanguageCatalog.normalizedIdentifier(selection),
            systemLocaleIdentifier: systemLocaleIdentifier
        ).localeLanguageCode
        return resolved.isEmpty ? "en" : resolved
    }

    /// Translates the catalogue identifier into the `transcription_config.model`
    /// value (`speechmatics/enhanced-streaming` → `enhanced`).
    public static func accuracyModel(from modelID: String) -> String {
        let raw = modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "speechmatics/", with: "")
            .replacingOccurrences(of: "-streaming", with: "")
        return raw.isEmpty ? defaultModel : raw
    }
}

/// Failures the shared Speechmatics realtime transport reports.
public enum SpeechmaticsRealtimeError: LocalizedError, Equatable {
    /// `not_authorised` — a missing, wrong or revoked key.
    case unauthorized
    /// `quota_exceeded` / `job_error` for an exhausted allowance. A stored key
    /// is never read as entitlement.
    case quotaExceeded(message: String)
    case server(message: String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Speechmatics rejected the API key. Check it in Settings."
        case .quotaExceeded(let message):
            return "Speechmatics allowance exhausted: \(message)"
        case .server(let message):
            return "Speechmatics realtime error: \(message)"
        }
    }

    /// Classifies an `Error` message frame by its documented `type` — one of
    /// `not_authorised`, `not_allowed`, `quota_exceeded`, `timelimit_exceeded`,
    /// `job_error`, `invalid_*`, `protocol_error`, `idle_timeout`,
    /// `session_timeout`, `unknown_error`. The free-text `reason` can carry
    /// submitted content, so it is reported but never used to infer a
    /// credential problem on its own.
    static func classify(type: String?, reason: String) -> SpeechmaticsRealtimeError {
        switch (type ?? "").lowercased() {
        case "not_authorised", "not_authorized", "not_allowed":
            return .unauthorized
        case "quota_exceeded", "timelimit_exceeded":
            return .quotaExceeded(message: reason)
        default:
            return .server(message: reason)
        }
    }
}

/// One decoded Speechmatics `v2` server frame.
///
/// Keeping the frame vocabulary beside the constants leaves the client with a
/// flat dispatch and one place to look when the protocol changes. Frames the
/// app does not act on — `Info`, `Warning`, anything added upstream — decode to
/// `nil` and are ignored: an unrecognised frame must never end a recording.
enum SpeechmaticsRealtimeEvent {
    case recognitionStarted
    case audioAdded(seqNo: Int)
    case partial(String)
    case final(String)
    case endOfTranscript
    case failure(SpeechmaticsRealtimeError)

    // One case per documented frame is the point of this switch: the protocol
    // vocabulary stays auditable in one place.
    // swiftlint:disable:next cyclomatic_complexity
    init?(object: [String: Any]) {
        guard let name = object["message"] as? String else { return nil }
        switch name {
        case "RecognitionStarted":
            self = .recognitionStarted
        case "AudioAdded":
            guard let seqNo = object["seq_no"] as? Int else { return nil }
            self = .audioAdded(seqNo: seqNo)
        case "AddPartialTranscript":
            guard let text = Self.transcript(from: object) else { return nil }
            self = .partial(text)
        case "AddTranscript":
            guard let text = Self.transcript(from: object) else { return nil }
            self = .final(text)
        case "EndOfTranscript":
            self = .endOfTranscript
        case "Error":
            self = .failure(.classify(
                type: object["type"] as? String,
                reason: (object["reason"] as? String) ?? "Unknown Speechmatics error"
            ))
        default:
            return nil
        }
    }

    /// `metadata.transcript` is the assembled text for the span, which already
    /// carries Speechmatics' own spacing and punctuation. The `results` array
    /// is per-word and is not re-joined here, because joining it would insert
    /// spaces before punctuation.
    ///
    /// The published examples put the text at `metadata.transcript`; the schema
    /// table in the API reference renders it as a top-level `transcript`. Both
    /// are read, so whichever the service actually sends is handled rather than
    /// silently dropped.
    static func transcript(from object: [String: Any]) -> String? {
        let metadata = object["metadata"] as? [String: Any]
        let text = (metadata?["transcript"] as? String) ?? (object["transcript"] as? String)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
