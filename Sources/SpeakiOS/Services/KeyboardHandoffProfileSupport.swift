#if os(iOS)
import Foundation
import SpeakCore

/// What a keyboard dictation profile needs from the app: whether its
/// transcription and polish routes are usable here, the polish itself, and
/// the History record of a completed hand-off.
@MainActor
enum KeyboardHandoffProfileSupport {
    static func isAvailable(_ profile: KeyboardDictationProfileOption) -> Bool {
        AppSettings.shared.profileAvailability(
            transcriptionModel: profile.transcriptionModelIdentifier,
            usesBatch: profile.transcriptionMode == .batch,
            postProcessingModel: profile.polishes ? profile.postProcessingModelIdentifier : nil
        ).isAvailable
    }

    static func polish(_ transcript: String, with profile: KeyboardDictationProfileOption) async throws -> String {
        guard let model = profile.postProcessingModelIdentifier else { return transcript }
        let response = try await iOSPostProcessingManager.shared.polish(
            text: transcript,
            model: model,
            apiKey: AppSettings.shared.postProcessingAPIKey(for: model)
        )
        let polished = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else { throw PostProcessingError.emptyResult }
        return polished
    }

    static func saveToHistory(_ transcript: String, result: TranscriptionResult) async {
        _ = await iOSHistoryManager.shared.recordTranscriptionAndWait(
            text: transcript,
            model: result.modelIdentifier,
            duration: result.duration
        )
    }
}
#endif
