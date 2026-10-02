import Foundation
import SpeakCore
import XCTest

final class StreamingFinalisationBudgetTests: XCTestCase {
    func testExistingConformersRetainUnspecifiedBudget() {
        let client: any FinalizingStreamingTranscriptionClient = DefaultBudgetClient()
        XCTAssertNil(client.finalisationBudget)
    }

    func testElevenLabsBudgetDispatchesThroughSharedProtocol() {
        let client: any FinalizingStreamingTranscriptionClient = ElevenLabsLiveClient(apiKey: "test-key")
        XCTAssertEqual(client.finalisationBudget, ElevenLabsLiveClient.finishDrainBudget)
        XCTAssertEqual(client.finalisationBudget, 10)
    }
}

private final class DefaultBudgetClient: FinalizingStreamingTranscriptionClient {
    let finalShape = TranscriptFinalShape.standaloneSegments
    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {}
    func sendAudio(_ audioData: Data) {}
    func stop() {}
    func finishAndWait() async -> String? { nil }
}
