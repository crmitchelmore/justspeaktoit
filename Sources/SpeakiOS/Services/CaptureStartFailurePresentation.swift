#if os(iOS)
import Foundation
import SpeakCore

enum CaptureStartFailureRecovery: String, Equatable, Hashable, Sendable {
    case appPermissions
    case credentials
    case prepareAppleModel

    var buttonTitle: String {
        switch self {
        case .appPermissions: return "Open Settings"
        case .credentials: return "API Keys"
        case .prepareAppleModel: return "Prepare Apple Model"
        }
    }
}

/// Safe user-facing copy for a failed recording start.
///
/// The original error remains available to private diagnostics. Only this
/// closed mapping reaches intents or start-failure alerts, so provider response
/// bodies, credential material and arbitrary model strings cannot leak there.
struct CaptureStartFailurePresentation: LocalizedError, Equatable, Sendable {
    let message: String
    let code: String
    let recovery: CaptureStartFailureRecovery?

    var errorDescription: String? { self.message }

    private init(
        message: String,
        code: String,
        recovery: CaptureStartFailureRecovery?
    ) {
        self.message = message
        self.code = code
        self.recovery = recovery
    }

    static func make(for error: Error) -> CaptureStartFailurePresentation {
        if let presentation = error as? CaptureStartFailurePresentation {
            return presentation
        }
        if let transcriptionError = error as? iOSTranscriptionError {
            return self.make(for: transcriptionError)
        }
        if let credentialError = error as? AppSettings.CredentialLoadingError,
           case .unavailable = credentialError {
            return self.credentialsUnavailable
        }
        if let streamingError = error as? StreamingClientError,
           case .missingAPIKey = streamingError {
            return self.missingAPIKey
        }
        if let failure = error as? CaptureParameterFailure {
            return CaptureStartFailurePresentation(
                message: failure.localizedDescription,
                code: "start_parameter_\(failure.rawValue)",
                recovery: nil
            )
        }
        if let failure = error as? CaptureLinkFailure {
            return CaptureStartFailurePresentation(
                message: failure.localizedDescription,
                code: "start_link_\(failure.rawValue)",
                recovery: nil
            )
        }
        let cocoaError = error as NSError
        if cocoaError.domain == "AppleSpeechPreparation", cocoaError.code == 1 {
            return self.appleModelUnprepared
        }
        return self.unknown
    }

    private static func make(for error: iOSTranscriptionError) -> CaptureStartFailurePresentation {
        switch error {
        case .permissionDenied(.microphone):
            return self.microphonePermission
        case .permissionDenied(.speechRecognition):
            return self.speechRecognitionPermission
        case .recognizerUnavailable:
            return self.recognizerUnavailable
        case .audioSessionFailed:
            return self.audioSessionFailed
        case .recognitionFailed:
            return self.recognitionFailed
        case .microphoneChanged:
            return self.microphoneChanged
        case .interrupted:
            return self.interrupted
        case .liveActivityUnavailable:
            return self.liveActivityUnavailable
        case .offlineLocalRecognitionUnavailable:
            return self.offlineLocalRecognitionUnavailable
        case .startTimedOut(let stage):
            let boundary = stage.map(iOSTranscriptionError.describe) ?? "starting"
            return CaptureStartFailurePresentation(
                message: "Recording didn't start in time while \(boundary). Try again.",
                code: "start_timeout",
                recovery: nil
            )
        case .microphoneDeliveredNoAudio:
            return self.microphoneDeliveredNoAudio
        case .finalisationTimedOut:
            return self.finalisationTimedOut
        }
    }

    private static let microphonePermission = CaptureStartFailurePresentation(
        message: "Microphone access is off. Allow it in Settings, then try again.",
        code: "start_permission_microphone",
        recovery: .appPermissions
    )
    private static let speechRecognitionPermission = CaptureStartFailurePresentation(
        message: "Speech Recognition access is off. Allow it in Settings, then try again.",
        code: "start_permission_speech_recognition",
        recovery: .appPermissions
    )
    private static let recognizerUnavailable = CaptureStartFailurePresentation(
        message: "Speech recognition is unavailable for the selected language. Choose another language and try again.",
        code: "start_recognizer_unavailable",
        recovery: nil
    )
    private static let audioSessionFailed = CaptureStartFailurePresentation(
        message: "The microphone audio session couldn't start. Finish other audio activity and try again.",
        code: "start_audio_session",
        recovery: nil
    )
    private static let recognitionFailed = CaptureStartFailurePresentation(
        message: "Speech recognition couldn't start. Try again, or open the app to check your setup.",
        code: "start_recognition",
        recovery: nil
    )
    private static let microphoneChanged = CaptureStartFailurePresentation(
        message: "The microphone changed before recording could start. Try again.",
        code: "start_microphone_changed",
        recovery: nil
    )
    private static let interrupted = CaptureStartFailurePresentation(
        message: "Audio was interrupted before recording could start. Try again when the interruption ends.",
        code: "start_interrupted",
        recovery: nil
    )
    private static let liveActivityUnavailable = CaptureStartFailurePresentation(
        message: "Recording needs Live Activities. Open the app, or enable Live Activities in Settings, then try again.",
        code: "start_live_activity",
        recovery: .appPermissions
    )
    private static let offlineLocalRecognitionUnavailable = CaptureStartFailurePresentation(
        message: "On-device speech recognition is unavailable for the selected language. "
            + "Choose another language or try again when online.",
        code: "start_offline_local_unavailable",
        recovery: nil
    )
    private static let microphoneDeliveredNoAudio = CaptureStartFailurePresentation(
        message: "The microphone delivered no audio. Check the selected microphone and try again.",
        code: "start_no_audio",
        recovery: nil
    )
    private static let finalisationTimedOut = CaptureStartFailurePresentation(
        message: "The previous transcript didn't finish in time. Try starting a new recording.",
        code: "start_finalisation_timeout",
        recovery: nil
    )
    private static let credentialsUnavailable = CaptureStartFailurePresentation(
        message: "Secure storage is temporarily unavailable. Unlock this iPhone and try again.",
        code: "start_credentials_unavailable",
        recovery: nil
    )
    private static let missingAPIKey = CaptureStartFailurePresentation(
        message: "This transcription model needs an API key. Add it in Settings, then try again.",
        code: "start_missing_api_key",
        recovery: .credentials
    )
    private static let appleModelUnprepared = CaptureStartFailurePresentation(
        message: "Apple's on-device speech model is not ready. Prepare it in Settings, then try again.",
        code: "start_apple_model_unprepared",
        recovery: .prepareAppleModel
    )

    private static let unknown = CaptureStartFailurePresentation(
        message: "Recording couldn't start. Try again, or open the app to check your setup.",
        code: "start_unknown",
        recovery: nil
    )
}
#endif
