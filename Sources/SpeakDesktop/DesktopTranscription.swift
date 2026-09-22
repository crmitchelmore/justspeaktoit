import Foundation
import SpeakCore

/// A projection of the canonical catalogue, limited to transports wired into
/// the desktop host. Adding a catalogue entry does not claim OS/runtime support.
public enum DesktopTranscription {
    public static var batchModels: [ModelCatalog.Option] {
        ModelCatalog.batchTranscription.filter {
            OpenAITranscriptionModels.directBatchModelIDs.contains($0.id)
        }
    }

    public static func transcribe(
        audioURL: URL,
        model: String,
        apiKey: String,
        duration: TimeInterval,
        language: String? = nil
    ) async throws -> TranscriptionResult {
        guard batchModels.contains(where: { $0.id == model }) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionProviderError.apiKeyMissing
        }
        try Task.checkCancellation()
        return try await OpenAIBatchClient(durationResolver: { _ in duration }).transcribeFile(
            at: audioURL, apiKey: apiKey, model: model, language: language
        )
    }
}

public enum DesktopTranscriptionError: LocalizedError {
    case unsupportedModel

    public var errorDescription: String? {
        "This model is not yet supported by the Windows recording workflow."
    }
}
