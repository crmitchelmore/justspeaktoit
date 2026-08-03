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
            case .deepgram:
                expectedBackend = .deepgram
            case .elevenlabs:
                expectedBackend = .elevenLabs
            case .openai:
                expectedBackend = .openAI
            default:
                expectedBackend = .shared(route.provider)
            }
            XCTAssertEqual(resolution.backend, expectedBackend, route.modelID)
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
