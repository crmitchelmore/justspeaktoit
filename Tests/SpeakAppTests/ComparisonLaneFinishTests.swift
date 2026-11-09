import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// Lane finish and error reporting for Compare Models: a client that finishes
/// without confirming text keeps its interim text visible but fails, and refused loopback
/// Azure endpoints name the local proxy.
@MainActor
final class ComparisonLaneFinishTests: XCTestCase {
    func testFinishWithNoConfirmedTextKeepsTheInterimTextButMarksTheLaneFailed() async throws {
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "deepgram/flux-general-en-streaming"))
        let client = NilFinishingClient()
        let lane = ComparisonLiveLane(candidate: ComparisonCandidate(
            modelID: route.modelID, displayName: "Flux fixture", providerDisplayName: "Deepgram",
            engine: .sharedStreamingClient(route), supportsStreaming: true, supportsFile: false,
            unavailableReason: nil
        ))
        lane.clientFactory = { client }
        defer { lane.abandon() }
        try lane.openSharedClient(
            route: route, apiKey: "synthetic-unused-key", language: nil, keywords: [], azureEndpoint: "",
            onTranscript: { _, _ in }
        )
        lane.record(text: "Streamed words", isFinal: false)

        await lane.finish(stoppedAt: Date())

        XCTAssertEqual(lane.entry.transcript, "Streamed words")
        XCTAssertEqual(lane.entry.errorDescription, "The model finished without confirming a final transcript.")
        XCTAssertNotNil(lane.entry.timeToFinalMs)
    }

    func testFinishBudgetOutlastsTheClientsOwnEightSecondDeadline() {
        XCTAssertGreaterThan(ComparisonLiveLane.finishBudget(for: "soniox/stt-rt-v5-streaming"), .seconds(8))
    }

    func testRefusedLoopbackAzureEndpointNamesTheLocalProxy() {
        let refused = URLError(.cannotConnectToHost)
        let message = ComparisonLiveLane.describe(
            refused, modelID: "azure/azure-speech-streaming", azureEndpoint: "http://127.0.0.1:8765"
        )
        XCTAssertTrue(message.contains("local Azure proxy"), message)
        XCTAssertTrue(message.contains("127.0.0.1:8765"), message)

        XCTAssertEqual(
            ComparisonLiveLane.describe(refused, modelID: "azure/azure-speech-streaming",
                                        azureEndpoint: "https://example.cognitiveservices.azure.com"),
            refused.localizedDescription
        )
        XCTAssertEqual(
            ComparisonLiveLane.describe(refused, modelID: "deepgram/nova-3-streaming",
                                        azureEndpoint: "http://127.0.0.1:8765"),
            refused.localizedDescription
        )
    }
}

private final class NilFinishingClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    let finalShape: TranscriptFinalShape = .standaloneSegments
    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {}
    func sendAudio(_ audioData: Data) {}
    func stop() {}
    func finishAndWait() async -> String? { nil }
}
