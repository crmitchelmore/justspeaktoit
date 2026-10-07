import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

final class DesktopOpenRouterFormatTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testStaticRouteRejectsWebMWithoutSendingOrMislabellingIt() async throws {
        let model = try XCTUnwrap(OpenRouterInlineAudioTranscriptionClient.batchCatalogIDs.first)
        do {
            _ = try await DesktopTranscription.transcribe(
                audioURL: URL(fileURLWithPath: "/absent/input.webm"), model: model,
                apiKey: "test", duration: 1, session: StubURLProtocol.makeSession()
            )
            XCTFail("Expected unsupported format")
        } catch {
            XCTAssertEqual(error as? OpenRouterInlineAudioTranscriptionClient.InputError, .unsupportedFormat)
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testDedicatedWebMRouteRetainsSavedIdentifierAfterEmptyDiscovery() async throws {
        let model = OpenRouterTranscriptionSelection.identifier(for: "vendor/saved-stt")
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".webm")
        defer { try? FileManager.default.removeItem(at: audio) }
        try Data([1, 2, 3]).write(to: audio)
        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/models") == true {
                return .ok(Data(#"{"data":[]}"#.utf8), url: request.url!)
            }
            XCTAssertEqual(request.url?.path, "/api/v1/audio/transcriptions")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            )
            XCTAssertEqual((body["input_audio"] as? [String: String])?["format"], "webm")
            return .ok(Data(#"{"text":"retained","usage":{"seconds":1}}"#.utf8), url: request.url!)
        }
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let store = OpenRouterAudioCatalogStore(session: session, cacheURL: nil)
        let state = await store.refresh()
        XCTAssertTrue(state.models.isEmpty)
        XCTAssertFalse(DesktopTranscription.batchModels(includingDiscovered: state.models).contains { $0.id == model })
        XCTAssertEqual(DesktopTranscription.provider(for: model)?.apiKeyIdentifier, "openrouter.apiKey")
        let result = try await DesktopTranscription.transcribe(
            audioURL: audio, model: model, apiKey: "test", duration: 1, session: session
        )
        XCTAssertEqual(result.modelIdentifier, model)
        XCTAssertEqual(result.text, "retained")
    }
}
