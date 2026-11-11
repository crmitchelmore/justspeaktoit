import Foundation

public enum SonioxBatchError: LocalizedError, Equatable {
    case unsupportedModel
    case transcriptionFailed(String)
    case transcriptionTimedOut

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel: return "This model is not a Soniox batch transcription model."
        case .transcriptionFailed(let message): return "Soniox transcription failed: \(message)"
        case .transcriptionTimedOut: return "Soniox transcription did not complete in time."
        }
    }
}
