import Foundation

/// What can truthfully be reported when transcription ends, independent of its destination.
public enum TranscriptionCompletionOutcome: String, Codable, Hashable, CaseIterable, Sendable {
    case ready
    case copied
    case savedToHistory
    case noSpeech

    /// Unconfirmed delivery or persistence must not become a copied/saved claim.
    public static func unconfirmed(transcript: String) -> Self {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noSpeech : .ready
    }

    /// Shared by the Lock Screen and expanded Dynamic Island.
    public var message: String {
        switch self {
        case .ready: "Transcription ready"
        case .copied: "Copied"
        case .savedToHistory: "Saved to history"
        case .noSpeech: "No speech detected"
        }
    }
}
