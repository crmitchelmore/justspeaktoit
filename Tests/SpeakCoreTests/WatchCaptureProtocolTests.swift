import XCTest
@testable import SpeakCore

final class WatchCaptureProtocolTests: XCTestCase {
    // ISO8601 (the wire date format) has whole-second precision, so use a
    // whole-second date for round-trip equality checks.
    private let wholeSecondDate = Date(timeIntervalSince1970: 1_754_500_000)

    // MARK: - Envelope round-trip

    func testEnvelope_roundTripsThroughTransferMetadata() throws {
        let envelope = WatchCaptureEnvelope(
            id: UUID(),
            createdAt: wholeSecondDate,
            duration: 61.5,
            fileExtension: "m4a"
        )

        let metadata = try XCTUnwrap(envelope.metadata())
        let decoded = try XCTUnwrap(WatchCaptureEnvelope.from(metadata: metadata))

        XCTAssertEqual(decoded, envelope)
    }

    func testEnvelopeMetadata_isPropertyListSafe() throws {
        let envelope = WatchCaptureEnvelope(duration: 5)
        let metadata = try XCTUnwrap(envelope.metadata())

        // WCSession metadata must be plist-serializable.
        XCTAssertTrue(PropertyListSerialization.propertyList(metadata, isValidFor: .binary))
    }

    func testEnvelopeDecoding_returnsNilForMissingOrMalformedMetadata() {
        XCTAssertNil(WatchCaptureEnvelope.from(metadata: nil))
        XCTAssertNil(WatchCaptureEnvelope.from(metadata: [:]))
        XCTAssertNil(WatchCaptureEnvelope.from(metadata: ["unrelated": "value"]))
        XCTAssertNil(WatchCaptureEnvelope.from(metadata: [WatchCaptureEnvelope.metadataKey: "not json"]))
        XCTAssertNil(WatchCaptureEnvelope.from(metadata: [WatchCaptureEnvelope.metadataKey: 42]))
    }

    func testEnvelopeDecoding_returnsNilForIncompatibleFutureSchema() throws {
        let future = WatchCaptureEnvelope(
            duration: 5,
            schemaVersion: WatchCaptureEnvelope.currentSchemaVersion + 1
        )
        let metadata = try XCTUnwrap(future.metadata())

        XCTAssertNil(WatchCaptureEnvelope.from(metadata: metadata))
    }

    func testEnvelopeDecoding_toleratesUnknownJSONKeys() throws {
        let json = """
        {"schemaVersion":1,"id":"\(UUID().uuidString)","createdAt":"2026-08-06T12:00:00Z",\
        "duration":12,"fileExtension":"m4a","futureField":"ignored"}
        """

        let decoded = WatchCaptureEnvelope.from(metadata: [WatchCaptureEnvelope.metadataKey: json])

        XCTAssertEqual(decoded?.duration, 12)
        XCTAssertEqual(decoded?.fileExtension, "m4a")
    }

    // MARK: - Ack round-trip

    func testAck_roundTripsThroughUserInfo() throws {
        let ack = WatchCaptureAck(id: UUID(), outcome: .transcribed)

        let userInfo = try XCTUnwrap(ack.userInfo())
        let decoded = try XCTUnwrap(WatchCaptureAck.from(userInfo: userInfo))

        XCTAssertEqual(decoded, ack)
    }

    func testFailedAck_carriesFailureMessage() throws {
        let ack = WatchCaptureAck(id: UUID(), outcome: .failed, message: "No API key")

        let decoded = try XCTUnwrap(WatchCaptureAck.from(userInfo: ack.userInfo()))

        XCTAssertEqual(decoded.outcome, .failed)
        XCTAssertEqual(decoded.message, "No API key")
    }

    func testAckDecoding_returnsNilForMissingOrMalformedUserInfo() {
        XCTAssertNil(WatchCaptureAck.from(userInfo: nil))
        XCTAssertNil(WatchCaptureAck.from(userInfo: [:]))
        XCTAssertNil(WatchCaptureAck.from(userInfo: [WatchCaptureAck.userInfoKey: "not json"]))
    }

    // MARK: - Status state machine

    func testStatusTransitions_allowOnlyTheDocumentedMatrix() {
        let allowed: [WatchCaptureStatus: Set<WatchCaptureStatus>] = [
            .recorded: [.transferring, .transcribed, .failed],
            .transferring: [.delivered, .failed, .transcribed],
            .delivered: [.transcribed, .failed, .transferring],
            .failed: [.transferring, .transcribed],
            .transcribed: []
        ]

        for source in WatchCaptureStatus.allCases {
            for target in WatchCaptureStatus.allCases {
                XCTAssertEqual(
                    source.canTransition(to: target),
                    allowed[source]?.contains(target) ?? false,
                    "\(source) → \(target)"
                )
            }
        }
    }

    func testRelaunchAfterLostTransferCallback_requeuesRetainedAudio() throws {
        // The on-disk state can still say transferring after WCSession has
        // completed and removed its transfer while our process was dead.
        let persisted = try JSONEncoder().encode(WatchCaptureStatus.transferring)
        let recovered = try JSONDecoder().decode(WatchCaptureStatus.self, from: persisted)
        XCTAssertTrue(recovered.shouldRetryTransfer(hasOutstandingTransfer: false))
        XCTAssertFalse(recovered.shouldRetryTransfer(hasOutstandingTransfer: true))
        XCTAssertFalse(recovered.canReleaseAudio)
    }

    func testDeliveredWithoutApplicationAck_keepsAudioAndRecoversOnActivation() {
        // WCSession success does not prove the receiver durably parked audio.
        XCTAssertFalse(WatchCaptureStatus.delivered.canReleaseAudio)
        XCTAssertTrue(WatchCaptureStatus.delivered.shouldRetryTransfer(hasOutstandingTransfer: false))
        XCTAssertTrue(WatchCaptureStatus.delivered.canTransition(to: .transferring))
    }

    func testEarlySuccessAck_survivesRelaunchAndRejectsLateTransportFailure() throws {
        XCTAssertTrue(WatchCaptureStatus.transferring.canTransition(to: .transcribed))
        let persisted = try JSONEncoder().encode(WatchCaptureStatus.transcribed)
        let recovered = try JSONDecoder().decode(WatchCaptureStatus.self, from: persisted)
        XCTAssertTrue(recovered.canReleaseAudio)
        XCTAssertFalse(recovered.shouldRetryTransfer(hasOutstandingTransfer: false))
        XCTAssertFalse(recovered.canTransition(to: .failed))
        XCTAssertFalse(recovered.canTransition(to: .delivered))
    }

    func testRecoveryPolicy_neverDuplicatesAnOutstandingTransfer() {
        for status in WatchCaptureStatus.allCases {
            XCTAssertFalse(status.shouldRetryTransfer(hasOutstandingTransfer: true), "\(status)")
        }
    }

    func testStatusIsTerminal_onlyForTranscribed() {
        for status in WatchCaptureStatus.allCases {
            XCTAssertEqual(status.isTerminal, status == .transcribed, "\(status)")
        }
    }
}
