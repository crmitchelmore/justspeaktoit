#if os(iOS)
import Foundation
import SpeakCore

/// Bridges the iOS settings objects onto the pure `PrivacyWorkflowSummary`
/// projection in SpeakCore. Keeping the projection itself platform-agnostic is
/// what lets the privacy disclosures be unit-tested without SwiftUI.
public extension PrivacyWorkflowSummary {
    @MainActor
    static func make(
        settings: AppSettings,
        voiceOutputEnabled: Bool,
        voiceOutputProvider: VoiceOutputProvider
    ) -> PrivacyWorkflowSummary {
        make(PrivacyWorkflowInputs(
            usesBatchTranscription: settings.transcriptionMode == .batch,
            liveTranscriptionModelID: settings.selectedModel,
            batchTranscriptionModelID: settings.batchTranscriptionModel,
            postProcessingEnabled: settings.postProcessingEnabled,
            postProcessingModelID: settings.postProcessingModel,
            voiceOutputEnabled: voiceOutputEnabled,
            voiceOutputProvider: voiceOutputProvider
        ))
    }

    /// Voice output on iOS runs through the OpenClaw gateway, so it only speaks
    /// when both the gateway and "Read Responses Aloud" are on.
    @MainActor
    static func make(settings: AppSettings, voiceOutput: OpenClawSettings) -> PrivacyWorkflowSummary {
        make(
            settings: settings,
            voiceOutputEnabled: voiceOutput.enabled && voiceOutput.ttsEnabled,
            voiceOutputProvider: voiceOutput.ttsProvider
        )
    }
}
#endif
