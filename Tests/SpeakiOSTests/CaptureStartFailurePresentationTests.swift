#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

final class CaptureStartFailurePresentationTests: XCTestCase {
    func testEveryTypedTranscriptionFailureHasStableSafePresentation() {
        let secret = SecretFailure()
        let cases: [(iOSTranscriptionError, String, CaptureStartFailureRecovery?)] = [
            (.permissionDenied(.microphone), "start_permission_microphone", .appPermissions),
            (.permissionDenied(.speechRecognition), "start_permission_speech_recognition", .appPermissions),
            (.recognizerUnavailable, "start_recognizer_unavailable", nil),
            (.audioSessionFailed(secret), "start_audio_session", nil),
            (.recognitionFailed(secret), "start_recognition", nil),
            (.microphoneChanged, "start_microphone_changed", nil),
            (.interrupted, "start_interrupted", nil),
            (.liveActivityUnavailable, "start_live_activity", .appPermissions),
            (.offlineLocalRecognitionUnavailable, "start_offline_local_unavailable", nil),
            (.startTimedOut(after: nil), "start_timeout", nil),
            (.startTimedOut(after: .credentialsReady), "start_timeout", nil),
            (.startTimedOut(after: .audioSessionConfigured), "start_timeout", nil),
            (.startTimedOut(after: .engineStarted), "start_timeout", nil),
            (.startTimedOut(after: .sessionStarted), "start_timeout", nil),
            (.startTimedOut(after: .firstPartial), "start_timeout", nil),
            (.microphoneDeliveredNoAudio, "start_no_audio", nil),
            (.finalisationTimedOut, "start_finalisation_timeout", nil)
        ]

        for (error, code, recovery) in cases {
            let presentation = CaptureStartFailurePresentation.make(for: error)
            XCTAssertEqual(presentation.code, code)
            XCTAssertEqual(presentation.recovery, recovery)
            XCTAssertFalse(presentation.message.isEmpty)
            XCTAssertFalse(presentation.message.contains(SecretFailure.secret))
        }
    }

    func testRepresentativeSafeCopyIsStableAndDoesNotOverclaim() {
        XCTAssertEqual(
            CaptureStartFailurePresentation.make(for: iOSTranscriptionError.permissionDenied(.microphone)).message,
            "Microphone access is off. Allow it in Settings, then try again."
        )
        XCTAssertEqual(
            CaptureStartFailurePresentation.make(for: iOSTranscriptionError.recognizerUnavailable).message,
            "Speech recognition is unavailable for the selected language. Choose another language and try again."
        )
        XCTAssertEqual(
            CaptureStartFailurePresentation.make(for: iOSTranscriptionError.audioSessionFailed(SecretFailure())).message,
            "The microphone audio session couldn't start. Finish other audio activity and try again."
        )
        XCTAssertEqual(
            CaptureStartFailurePresentation.make(for: iOSTranscriptionError.startTimedOut(after: .engineStarted)).message,
            "Recording didn't start in time while starting the microphone. Try again."
        )
    }

    @MainActor
    func testUnavailableSecureStorageIsDistinctFromAnActuallyMissingKey() {
        let unavailable = CaptureStartFailurePresentation.make(
            for: AppSettings.CredentialLoadingError.unavailable
        )
        let missing = CaptureStartFailurePresentation.make(
            for: StreamingClientError.missingAPIKey(provider: "private-provider-id")
        )

        XCTAssertEqual(unavailable.code, "start_credentials_unavailable")
        XCTAssertEqual(unavailable.recovery, nil)
        XCTAssertEqual(
            unavailable.message,
            "Secure storage is temporarily unavailable. Unlock this iPhone and try again."
        )
        XCTAssertEqual(missing.code, "start_missing_api_key")
        XCTAssertEqual(missing.recovery, .credentials)
        XCTAssertEqual(
            missing.message,
            "This transcription model needs an API key. Add it in Settings, then try again."
        )
        XCTAssertFalse(missing.message.contains("private-provider-id"))
        XCTAssertNotEqual(unavailable, missing)
    }

    func testOnlyTheExactOwnedApplePreparationErrorGetsPreparationRecovery() {
        let owned = NSError(domain: "AppleSpeechPreparation", code: 1, userInfo: [
            NSLocalizedDescriptionKey: SecretFailure.secret
        ])
        let wrongCode = NSError(domain: "AppleSpeechPreparation", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Apple model is missing"
        ])
        let similarText = NSError(domain: "Unrelated", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "AppleSpeechPreparation code 1 prepare Apple model"
        ])

        let presentation = CaptureStartFailurePresentation.make(for: owned)
        XCTAssertEqual(presentation.code, "start_apple_model_unprepared")
        XCTAssertEqual(presentation.recovery, .prepareAppleModel)
        XCTAssertEqual(
            presentation.message,
            "Apple's on-device speech model is not ready. Prepare it in Settings, then try again."
        )
        XCTAssertEqual(CaptureStartFailurePresentation.make(for: wrongCode).code, "start_unknown")
        XCTAssertEqual(CaptureStartFailurePresentation.make(for: similarText).code, "start_unknown")
        XCTAssertFalse(presentation.message.contains(SecretFailure.secret))
    }

    func testUnknownAndWrappedErrorsNeverExposeArbitraryDetails() {
        let errors: [Error] = [
            SecretFailure(),
            NSError(domain: "Provider", code: 503, userInfo: [
                NSLocalizedDescriptionKey: SecretFailure.secret,
                NSUnderlyingErrorKey: StreamingClientError.missingAPIKey(provider: "hidden-provider")
            ]),
            CaptureStartFailurePolicy.PresentedFailure(message: SecretFailure.secret),
            StreamingClientError.invalidAPIKey(provider: "hidden-provider")
        ]

        for error in errors {
            let presentation = CaptureStartFailurePresentation.make(for: error)
            XCTAssertEqual(presentation.code, "start_unknown")
            XCTAssertEqual(presentation.recovery, nil)
            XCTAssertFalse(presentation.message.contains(SecretFailure.secret))
            XCTAssertFalse(presentation.message.contains("hidden-provider"))
            XCTAssertFalse(presentation.message.lowercased().contains("permission"))
            XCTAssertFalse(presentation.message.lowercased().contains("declin"))
        }
    }

    func testParameterAndLinkFailuresKeepTheirMeaning() {
        for failure in CaptureParameterFailure.allCases {
            let presentation = CaptureStartFailurePresentation.make(for: failure)
            XCTAssertEqual(presentation.code, "start_parameter_\(failure.rawValue)")
            XCTAssertEqual(presentation.message, failure.localizedDescription)
            XCTAssertEqual(presentation.recovery, nil)
            XCTAssertFalse(presentation.message.lowercased().contains("permission"))
        }
        for failure in CaptureLinkFailure.allCases {
            let presentation = CaptureStartFailurePresentation.make(for: failure)
            XCTAssertEqual(presentation.code, "start_link_\(failure.rawValue)")
            XCTAssertEqual(presentation.message, failure.localizedDescription)
            XCTAssertEqual(presentation.recovery, nil)
        }
    }

    func testUnderlyingDescriptionsAreSanitizedAtThePublicErrorBoundary() {
        XCTAssertFalse(
            iOSTranscriptionError.audioSessionFailed(SecretFailure())
                .localizedDescription.contains(SecretFailure.secret)
        )
        XCTAssertFalse(
            iOSTranscriptionError.recognitionFailed(SecretFailure())
                .localizedDescription.contains(SecretFailure.secret)
        )
    }

    func testRecoveryButtonsNameOnlySupportedDestinations() {
        XCTAssertEqual(CaptureStartFailureRecovery.appPermissions.buttonTitle, "Open Settings")
        XCTAssertEqual(CaptureStartFailureRecovery.credentials.buttonTitle, "API Keys")
        XCTAssertEqual(CaptureStartFailureRecovery.prepareAppleModel.buttonTitle, "Prepare Apple Model")
    }
}

private struct SecretFailure: LocalizedError {
    static let secret = "sk-secret provider.example/v1 response-body"
    var errorDescription: String? { Self.secret }
}
#endif
