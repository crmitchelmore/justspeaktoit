#if os(iOS)
import XCTest
import SpeakCore

@testable import SpeakiOSLib

final class IOSTranscriptionSessionTests: XCTestCase {
    @MainActor
    func testEverySelectableLiveModelResolvesAndConstructsThroughSharedFactory() throws {
        var checkedModelIDs: Set<String> = []

        for model in ModelCatalog.liveTranscription {
            guard
                let route = LiveTranscriptionRouting.route(for: model.id),
                route.provider.isSupportedOnIOS
            else {
                continue
            }

            let resolution = try IOSTranscriptionSession.resolve(
                modelID: model.id,
                mode: .streaming
            )
            XCTAssertEqual(resolution.modelID, route.modelID)
            XCTAssertEqual(resolution.route, route)
            XCTAssertEqual(resolution.sampleRate, route.sampleRate)

            let session = try IOSTranscriptionSession(
                modelID: model.id,
                mode: .streaming,
                audioSessionManager: AudioSessionManager(),
                batchAPIKey: "",
                liveAPIKey: { _ in "test-key" }
            )
            XCTAssertEqual(session.resolution, resolution)
            checkedModelIDs.insert(model.id)
        }

        let expectedModelIDs: Set<String> = Set(
            ModelCatalog.liveTranscription.compactMap { model in
                guard LiveTranscriptionRouting.route(for: model.id)?.provider.isSupportedOnIOS == true else {
                    return nil
                }
                return model.id
            }
        )
        XCTAssertEqual(checkedModelIDs, expectedModelIDs)
        XCTAssertFalse(checkedModelIDs.isEmpty)
    }

    func testProviderKindsUseOneCanonicalRoutingDecision() throws {
        for route in LiveTranscriptionRouting.allRoutes where route.provider.isSupportedOnIOS {
            let resolution = try IOSTranscriptionSession.resolve(
                modelID: route.modelID,
                mode: .streaming
            )
            let expectedBackend: IOSTranscriptionSession.BackendKind
            switch route.provider {
            case .apple:
                expectedBackend = .apple
            case .openai:
                expectedBackend = .openAI
            default:
                expectedBackend = .shared(route.provider)
            }
            XCTAssertEqual(resolution.backend, expectedBackend, route.modelID)
        }
    }

    /// Deepgram and ElevenLabs used to have bespoke iOS transcribers; they now
    /// run on the same generic capture path as every other shared-client
    /// provider, with their model/sample-rate wiring coming from the route.
    func testDeepgramAndElevenLabsResolveToTheSharedCapturePath() throws {
        let deepgram = try IOSTranscriptionSession.resolve(
            modelID: "deepgram/nova-3-streaming",
            mode: .streaming
        )
        XCTAssertEqual(deepgram.backend, .shared(.deepgram))
        XCTAssertEqual(deepgram.route?.apiModelName, "nova-3")
        XCTAssertEqual(deepgram.sampleRate, 16_000)

        let elevenLabs = try IOSTranscriptionSession.resolve(
            modelID: "elevenlabs/scribe-v2-streaming",
            mode: .streaming
        )
        XCTAssertEqual(elevenLabs.backend, .shared(.elevenlabs))
        XCTAssertEqual(elevenLabs.route?.apiModelName, "scribe_v2_realtime")
        XCTAssertEqual(elevenLabs.sampleRate, 16_000)
    }

    /// A blank key never reaches the microphone: the shared transcriber fails
    /// before configuring the audio session, as the bespoke providers did.
    @MainActor
    func testSharedTranscriberRejectsBlankAPIKeyBeforeCapture() async {
        let route = try? XCTUnwrap(LiveTranscriptionRouting.route(for: "deepgram/nova-3-streaming"))
        guard let route else { return XCTFail("missing deepgram route") }
        let transcriber = SharedClientLiveTranscriber(
            route: route,
            apiKey: "   ",
            audioSessionManager: AudioSessionManager()
        )

        do {
            try await transcriber.start()
            XCTFail("expected a missing-API-key error")
        } catch {
            XCTAssertFalse(transcriber.isRunning)
            guard case StreamingClientError.missingAPIKey = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testBatchModeUsesSameFactoryWithoutLiveProviderRouting() throws {
        let resolution = try IOSTranscriptionSession.resolve(
            modelID: "openai/gpt-4o-mini-transcribe",
            mode: .batch(retainRecording: false)
        )

        XCTAssertEqual(resolution.backend, .batch)
        XCTAssertEqual(resolution.modelID, "openai/gpt-4o-mini-transcribe")
        XCTAssertNil(resolution.route)
        XCTAssertTrue(resolution.isBatch)
    }
}
#endif
