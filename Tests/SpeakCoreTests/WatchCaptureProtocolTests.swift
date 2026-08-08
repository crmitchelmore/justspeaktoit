import XCTest
@testable import SpeakCore

final class WatchCaptureProtocolTests: XCTestCase {
    // ISO8601 (the wire date format) has whole-second precision, so use a
    // whole-second date for round-trip equality checks.
    private let wholeSecondDate = Date(timeIntervalSince1970: 1_754_500_000)

    // MARK: - Envelope round-trip

    func testEnvelopeRoundTripsThroughMetadata() throws {
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

    func testEnvelopeMetadataIsPropertyListSafe() throws {
        let envelope = WatchCaptureEnvelope(duration: 5)
        let metadata = try XCTUnwrap(envelope.metadata())

        // WCSession metadata must be plist-serializable.
        XCTAssertTrue(PropertyListSerialization.propertyList(metadata, isValidFor: .binary))
    }

    func testEnvelopeFromMissingOrMalformedMetadataIsNil() {
        XCTAssertNil(WatchCaptureEnvelope.from(metadata: nil))
        XCTAssertNil(WatchCaptureEnvelope.from(metadata: [:]))
        XCTAssertNil(WatchCaptureEnvelope.from(metadata: ["unrelated": "value"]))
        XCTAssertNil(WatchCaptureEnvelope.from(metadata: [WatchCaptureEnvelope.metadataKey: "not json"]))
        XCTAssertNil(WatchCaptureEnvelope.from(metadata: [WatchCaptureEnvelope.metadataKey: 42]))
    }

    func testEnvelopeFromIncompatibleFutureSchemaIsNil() throws {
        let future = WatchCaptureEnvelope(
            duration: 5,
            schemaVersion: WatchCaptureEnvelope.currentSchemaVersion + 1
        )
        let metadata = try XCTUnwrap(future.metadata())

        XCTAssertNil(WatchCaptureEnvelope.from(metadata: metadata))
    }

    func testEnvelopeToleratesUnknownJSONKeys() throws {
        let json = """
        {"schemaVersion":1,"id":"\(UUID().uuidString)","createdAt":"2026-08-06T12:00:00Z",\
        "duration":12,"fileExtension":"m4a","futureField":"ignored"}
        """

        let decoded = WatchCaptureEnvelope.from(metadata: [WatchCaptureEnvelope.metadataKey: json])

        XCTAssertEqual(decoded?.duration, 12)
        XCTAssertEqual(decoded?.fileExtension, "m4a")
    }

    // MARK: - Ack round-trip

    func testAckRoundTripsThroughUserInfo() throws {
        let ack = WatchCaptureAck(id: UUID(), outcome: .transcribed)

        let userInfo = try XCTUnwrap(ack.userInfo())
        let decoded = try XCTUnwrap(WatchCaptureAck.from(userInfo: userInfo))

        XCTAssertEqual(decoded, ack)
    }

    func testFailedAckCarriesMessage() throws {
        let ack = WatchCaptureAck(id: UUID(), outcome: .failed, message: "No API key")

        let decoded = try XCTUnwrap(WatchCaptureAck.from(userInfo: ack.userInfo()))

        XCTAssertEqual(decoded.outcome, .failed)
        XCTAssertEqual(decoded.message, "No API key")
    }

    func testAckFromMissingOrMalformedUserInfoIsNil() {
        XCTAssertNil(WatchCaptureAck.from(userInfo: nil))
        XCTAssertNil(WatchCaptureAck.from(userInfo: [:]))
        XCTAssertNil(WatchCaptureAck.from(userInfo: [WatchCaptureAck.userInfoKey: "not json"]))
    }

    // MARK: - Status state machine

    func testStatusTransitionMatrix() {
        let allowed: [WatchCaptureStatus: Set<WatchCaptureStatus>] = [
            .recorded: [.transferring],
            .transferring: [.delivered, .failed],
            .delivered: [.transcribed, .failed],
            .failed: [.transferring],
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

    func testOnlyTranscribedIsTerminal() {
        for status in WatchCaptureStatus.allCases {
            XCTAssertEqual(status.isTerminal, status == .transcribed, "\(status)")
        }
    }
}
