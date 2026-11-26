import SpeakCore

final class UnsupportedLocalLiveTranscriber: LiveTranscriptionController {
    weak var delegate: LiveTranscriptionSessionDelegate?
    private(set) var isRunning = false

    func configure(language: String?, model: String) {}

    func start() async throws {
        throw TranscriptionManagerError.localLiveStreamingUnsupported
    }

    func stop() async {
        isRunning = false
    }
}
