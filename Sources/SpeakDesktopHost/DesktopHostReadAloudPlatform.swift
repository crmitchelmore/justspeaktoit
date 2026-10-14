import Foundation
import SpeakCore
import SpeakDesktop

package protocol DesktopHostReadAloudPlatform: DesktopHostPlatform
where Playback: DesktopHostSpeechPlayback, VoiceOutputSettings == DesktopVoiceOutputSettings,
      ReadAloudState == DesktopHostReadAloudState<Playback.Speech, VoiceOutput> {
    associatedtype VoiceOutput: DesktopHostVoiceOutput
    /// The engine, staging synthesized audio in `directory`, which it creates
    /// readable only by the current user.
    static func makeVoiceOutput(stagingDirectory directory: URL) throws -> VoiceOutput
    static func voiceCredential(
        _ result: Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError>, requestID: UUID)
    static func voiceCredentialFinished(
        _ result: Result<Void, VoiceOutputCredentialError>, request: VoiceOutputCredentialRequest)
    static func voiceAccountProviders(_ presentation: DesktopVoiceAccountProvidersPresentation)
    static func voiceProviderCredential(
        _ result: Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError>,
        requestID: UUID, context: VoiceAccountCredentialContext)
    static func voiceProviderCredentialFinished(
        _ result: Result<Void, VoiceOutputCredentialError>, request: VoiceProviderCredentialRequest)
    static func synthesizeVoiceOutput(
        _ source: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        credential: @Sendable () async throws -> String
    ) async throws -> Data
    /// Where this window saves the Deepgram key, e.g. "choose a Deepgram
    /// model, then Save key", for the missing-key status line.
    static var deepgramKeyHint: String { get }
}

package extension DesktopHostReadAloudPlatform {
    static func voiceCredential(
        _ result: Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError>, requestID: UUID) {}
    static func voiceCredentialFinished(
        _ result: Result<Void, VoiceOutputCredentialError>, request: VoiceOutputCredentialRequest) {}
    static func voiceAccountProviders(_ presentation: DesktopVoiceAccountProvidersPresentation) {}
    static func voiceProviderCredential(
        _ result: Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError>,
        requestID: UUID, context: VoiceAccountCredentialContext) {}
    static func voiceProviderCredentialFinished(
        _ result: Result<Void, VoiceOutputCredentialError>, request: VoiceProviderCredentialRequest) {}

    static func makeReadAloudState() -> ReadAloudState { ReadAloudState() }

    static func synthesizeVoiceOutput(
        _ source: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try await DesktopSpeechSynthesis().synthesize(
            source, voice: selection.voice, options: selection.options,
            accountInventory: selection.accountInventory, credential: credential
        )
    }

    /// Cancels the segment being synthesized, so no later one is admitted, and
    /// returns the record's controls to idle once nothing more will be spoken.
    static func stopReadAloud(_ state: inout ReadAloudState, playback: Playback) {
        state.task?.cancel()
        state.task = nil
        state.exportTask?.cancel()
        state.exportTask = nil
        if let speech = state.speech { playback.endSpeech(speech) }
        state.speech = nil
    }

    static func isReadingAloud(_ state: ReadAloudState) -> Bool { state.task != nil || state.exportTask != nil }
}
