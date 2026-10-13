import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    package func prepareRecordingFeedback(loader: (any DesktopRecordingFeedbackLoader)? = nil) async {
        guard !closed else { return }
        if recordingFeedback == nil, let loader = loader ?? Platform.makeRecordingFeedbackLoader() {
            recordingFeedback = DesktopRecordingFeedback(loader: loader) { [weak self] message in
                FileHandle.standardError.write(Data("\(message)\n".utf8))
                Task { await self?.recordingFeedbackFailed(message) }
            }
        }
        do { try await configureRecordingFeedback(configuration()) } catch {
            recordingFeedbackFailed(error.localizedDescription)
        }
    }

    func configureRecordingFeedback(_ configuration: DesktopConfiguration) async throws {
        guard let profile = RecordingFeedbackProfile(rawValue: configuration.text("recordingSoundProfile")) else {
            throw DesktopConfigurationError.invalidField("Recording sound profile")
        }
        let preferences = try DesktopRecordingFeedbackPreferences(
            enabled: configuration.enabled("recordingSoundsEnabled"), profile: profile,
            volume: Float(configuration.number("recordingSoundVolume"))
        )
        recordingFeedbackPreview?.cancel()
        await recordingFeedback?.configure(preferences)
    }

    package func previewRecordingFeedback(_ sound: RecordingFeedbackSound) throws {
        guard !closed, !busy, recording == nil else {
            throw DesktopHostError(message: "Finish dictation before previewing recording sounds.")
        }
        guard let feedback = recordingFeedback else {
            throw DesktopHostError(message: "Recording sound output is not available on this host.")
        }
        recordingFeedbackPreview?.cancel()
        recordingFeedbackPreview = Task { await feedback.preview(sound) }
    }

    private func recordingFeedbackFailed(_ message: String) {
        update("\(message) Dictation and its saved audio are unaffected.")
    }
}
