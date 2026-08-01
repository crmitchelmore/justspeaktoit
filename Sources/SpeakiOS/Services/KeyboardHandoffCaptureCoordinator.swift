#if os(iOS)
import Foundation
import SpeakCore

@MainActor
public final class KeyboardHandoffCaptureCoordinator: ObservableObject {
    public enum Phase: Equatable {
        case preparing
        case recording
        case transcribing
        case ready
        case cancelled
        case error
    }

    @Published public private(set) var phase: Phase = .preparing
    @Published public private(set) var message = "Preparing a private one-time handoff…"

    public let requestID: UUID

    private let store: KeyboardHandoffStore
    private let recordingService: TranscriptionRecordingService
    private var started = false

    public init(
        requestID: UUID,
        store: KeyboardHandoffStore = .shared,
        recordingService: TranscriptionRecordingService
    ) {
        self.requestID = requestID
        self.store = store
        self.recordingService = recordingService
    }

    public convenience init(requestID: UUID) {
        self.init(
            requestID: requestID,
            store: .shared,
            recordingService: .shared
        )
    }

    public func start() async {
        guard !started else { return }
        started = true

        guard store.record(matching: requestID)?.phase == .requested else {
            fail(code: .invalidRequest, message: "This keyboard request is no longer active.")
            return
        }
        guard !recordingService.isRunning else {
            fail(code: .recordingUnavailable, message: "Another recording is already in progress.")
            return
        }

        do {
            try store.markRecording(requestID: requestID)
            try await recordingService.startRecording(
                retainBatchRecording: false,
                sharesLiveTranscript: false
            )
            phase = .recording
            message = "Speak now. Tap Finish when you’re done."
        } catch {
            recordingService.cancelRecording()
            fail(
                code: .recordingUnavailable,
                message: "Recording could not start. Check microphone and speech permissions."
            )
        }
    }

    public func finish() async {
        guard phase == .recording else { return }
        do {
            try store.markTranscribing(requestID: requestID)
        } catch {
            recordingService.cancelRecording()
            fail(code: .invalidRequest, message: "The keyboard request expired before transcription.")
            return
        }

        phase = .transcribing
        message = "Finishing with your selected transcription model…"
        let result = await recordingService.stopRecording(
            destination: .historyOnly,
            saveToHistory: true
        )
        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            fail(code: .noSpeech, message: "No speech was detected. Nothing will be inserted.")
            return
        }

        do {
            try store.complete(requestID: requestID, transcript: transcript)
            phase = .ready
            message = "Return to the previous app and choose Just Speak to insert the result."
        } catch {
            fail(code: .invalidRequest, message: "The request ended safely before a result could be shared.")
        }
    }

    public func cancel() {
        if recordingService.isRunning {
            recordingService.cancelRecording()
        }
        _ = try? store.cancel(requestID: requestID)
        phase = .cancelled
        message = "Cancelled. No transcript was shared with the keyboard."
    }

    private func fail(code: KeyboardHandoffRecord.FailureCode, message: String) {
        _ = try? store.fail(requestID: requestID, code: code)
        phase = .error
        self.message = message
    }
}
#endif
