import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
import SpeakDesktop

/// The desktop projection admits both canonical Azure Voice Live routes only
/// through the shared client, and only with the resource endpoint the host
/// stores. Synthetic key and resource only.
final class AzureVoiceLiveDesktopFactoryTests: XCTestCase {
    private let endpoint = "https://synthetic.cognitiveservices.azure.com"

    func testBothCanonicalRoutesAreProjectedWithTheSharedCredentialAndClient() throws {
        for option in AzureTranscriptionModels.liveOptions {
            XCTAssertTrue(DesktopLiveTranscription.liveModels.contains { $0.id == option.id }, option.id)
            let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: option.id))
            XCTAssertEqual(route.provider, .azure)
            XCTAssertEqual(route.sampleRate, 24_000)
            XCTAssertEqual(DesktopLiveTranscription.captureFrameMilliseconds(forID: option.id), 100)
            XCTAssertEqual(DesktopLiveTranscription.provider(forID: option.id)?.apiKeyIdentifier,
                           AzureSpeechConfiguration.credentialIdentifier)
            let client = DesktopLiveTranscription.makeClient(
                model: option.id, apiKey: "synthetic:uksouth", azureEndpoint: endpoint,
                makeConnection: { _ in fatalError("Constructing a client must not open a connection") }
            )
            XCTAssertTrue(client is AzureVoiceLiveClient, option.id)
            let budget = ModelCatalog.liveCapabilities(for: option.id).postStopFinalizeBudget
            XCTAssertEqual(client?.finalisationBudget, budget, "The finish is bounded by the catalogue's budget")
        }
    }

    func testTheHostsEndpointIsTheOnlyOriginAndAMissingOneFailsBeforeConnecting() throws {
        let sockets = AssemblyAISocketFactory()
        let configured = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: AzureTranscriptionModels.speechLive, apiKey: "synthetic:uksouth", azureEndpoint: endpoint,
            makeConnection: { sockets.make($0) }
        ))
        configured.start(onTranscript: { _, _ in }, onError: { XCTFail("Unexpected error: \($0)") })
        defer { configured.cancel() }
        let url = try XCTUnwrap(sockets.requests.first?.url)
        XCTAssertEqual(url.host, "synthetic.cognitiveservices.azure.com")
        XCTAssertEqual(url.path, "/voice-live/realtime")

        let unconfigured = AssemblyAISocketFactory()
        let errors = AssemblyAITestEvents()
        let missing = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: AzureTranscriptionModels.maiLive, apiKey: "synthetic:uksouth",
            makeConnection: { unconfigured.make($0) }
        ))
        missing.start(onTranscript: { _, _ in }, onError: { errors.fail($0) })
        XCTAssertTrue(unconfigured.sockets.isEmpty, "No regional fallback: nothing connects without a resource")
        XCTAssertEqual(errors.errors.count, 1)
    }

    func testTheRouteSendsItsCanonicalModelAndLeavesTheLanguageToAzure() throws {
        for option in AzureTranscriptionModels.liveOptions {
            let sockets = AssemblyAISocketFactory()
            let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
                model: option.id, apiKey: "synthetic:uksouth", language: "fr_FR", azureEndpoint: endpoint,
                makeConnection: { sockets.make($0) }
            ))
            client.start(onTranscript: { _, _ in }, onError: { XCTFail("Unexpected error: \($0)") })
            defer { client.cancel() }
            let socket = try XCTUnwrap(sockets.sockets.first)
            socket.open()
            let session = try XCTUnwrap(socket.sessionUpdate?["session"] as? [String: Any])
            let transcription = try XCTUnwrap(session["input_audio_transcription"] as? [String: Any])
            let apiModel = LiveTranscriptionRouting.route(for: option.id)?.apiModelName
            XCTAssertEqual(transcription["model"] as? String, apiModel)
            XCTAssertNil(transcription["language"], "The canonical capability takes no hint; Azure detects it")
            XCTAssertFalse(ModelCatalog.liveCapabilities(for: option.id).supportsLanguageHint)
        }
    }
}
