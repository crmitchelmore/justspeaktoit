import XCTest

@testable import SpeakApp

final class WhisperKitStreamingModelTests: XCTestCase {
    func testIdentifierRoundTrip_preservesBuiltInModel() {
        let streamingID = WhisperKitStreamingModel.id(forBatchModelID: "local/whisperkit/tiny")

        XCTAssertEqual(streamingID, "local/streaming/whisperkit/tiny")
        XCTAssertEqual(
            WhisperKitStreamingModel.batchModelID(from: streamingID),
            "local/whisperkit/tiny"
        )
    }

    func testBatchModelID_rejectsOtherStreamingRuntimes() {
        XCTAssertNil(
            WhisperKitStreamingModel.batchModelID(
                from: "local/streaming/fluidaudio/parakeet-realtime-eou-120m"
            )
        )
    }
}
