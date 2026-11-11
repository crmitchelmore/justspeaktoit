#if os(iOS)
import Foundation
import SpeakCore

/// What a keyboard dictation profile needs from the app: whether its
/// transcription and polish routes are usable here, the polish itself, and
/// the History record of a completed hand-off.
@MainActor
enum KeyboardHandoffProfileSupport {
    static func isAvailable(_ profile: KeyboardDictationProfileOption) -> Bool {
        let settings = AppSettings.shared
        if profile.transcriptionMode == .streaming {
            guard let route = LiveTranscriptionRouting.route(for: profile.transcriptionModelIdentifier),
                  route.isSupportedOnIOS else {
                return false
            }
            if route.apiKeyIdentifier != nil,
               settings.liveAPIKey(for: route).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        if profile.transcriptionMode == .batch {
            guard AppSettings.supportsBatchModel(profile.transcriptionModelIdentifier) else {
                return false
            }
            if profile.transcriptionModelIdentifier != AppleLocalModels.speechTranscriberModelID,
               settings.batchAPIKey(for: profile.transcriptionModelIdentifier)
                   .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        guard profile.polishes, let postProcessingModel = profile.postProcessingModelIdentifier else { return true }
        guard AppSettings.postProcessingModels.contains(where: {
            $0.id == postProcessingModel
        }) || CleanupModelSelection.modelID(from: postProcessingModel) != nil else {
            return false
        }
        if postProcessingModel == AppleLocalModels.foundationModelID {
            return AppleFoundationModelPolisher.isAvailable
        }
        return settings.hasPostProcessingKey(for: postProcessingModel)
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
