import XCTest

@testable import SpeakCore

final class TranscriptionModelAvailabilityTests: XCTestCase {
    private let azure = ModelCredentialRequirement.apiKey(identifier: "azure", providerName: "Azure Speech")

    func testEvaluate_reportsEachReasonAModelCannotRun() {
        XCTAssertEqual(
            evaluate(azure, executable: false, loaded: true, credential: "key").status,
            .unsupportedOnPlatform
        )
        XCTAssertEqual(evaluate(azure, loaded: false, credential: nil).status, .credentialsUnavailable)
        XCTAssertEqual(
            evaluate(azure, credential: "  \n"),
            TranscriptionModelAvailability(status: .missingCredential, providerName: "Azure Speech")
        )
        XCTAssertTrue(evaluate(azure, credential: "key").isAvailable)
    }

    func testEvaluate_keylessModelIsAvailableEvenWhenTheKeychainIsLocked() {
        XCTAssertTrue(evaluate(.notRequired, loaded: false, credential: nil).isAvailable)
    }

    func testFirst_reportsTheTranscriptionModelBeforeThePolishModel() {
        let missing = TranscriptionModelAvailability(status: .missingCredential, providerName: "Azure Speech")
        let locked = TranscriptionModelAvailability(status: .credentialsUnavailable, providerName: "OpenRouter")
        XCTAssertEqual(TranscriptionModelAvailability.first(of: [.available, missing, locked]), missing)
        XCTAssertEqual(TranscriptionModelAvailability.first(of: [.available, .available]), .available)
    }

    func testNoteAndErrorSayWhyAndThatNothingWasSubstituted() {
        let missing = TranscriptionModelAvailability(status: .missingCredential, providerName: "Azure Speech")
        XCTAssertNil(TranscriptionModelAvailability.available.note)
        XCTAssertEqual(missing.note, "Unavailable: Azure Speech API key not set")

        let error = TranscriptionModelUnavailableError(
            modelIdentifier: "azure/mai-transcribe-2-streaming",
            modelName: "MAI-Transcribe-2",
            availability: missing
        )
        let message = error.localizedDescription
        XCTAssertTrue(message.hasPrefix("MAI-Transcribe-2 is unavailable"), message)
        XCTAssertTrue(message.contains("Azure Speech API key isn't set"), message)
        XCTAssertTrue(message.contains("The recording was not started."), message)
    }

    private func evaluate(
        _ requirement: ModelCredentialRequirement,
        executable: Bool = true,
        loaded: Bool = true,
        credential: String?
    ) -> TranscriptionModelAvailability {
        .evaluate(
            requirement: requirement, isExecutableHere: executable, credentialsLoaded: loaded, credential: credential
        )
    }
}
