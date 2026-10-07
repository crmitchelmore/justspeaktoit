import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

/// The desktop live factory exposes exactly the canonical routes that have
/// shared clients, each built without opening a connection.
final class DesktopLiveCatalogueTests: XCTestCase {
    // One client-type expectation per projected provider: branches grow with the route list, not logic.
    // swiftlint:disable:next cyclomatic_complexity
    func testLiveProjectionAndDescriptorsUseCanonicalCatalogueAndRoutes() throws {
        let canonical = ModelCatalog.liveTranscription.filter {
            guard let route = LiveTranscriptionRouting.route(for: $0.id) else { return false }
            return [.deepgram, .assemblyai, .openai, .speechmatics, .soniox, .elevenlabs, .mistral, .gladia, .cartesia,
                    .revai, .azure].contains(route.provider) || route.modelID == XAISpeechToText.liveCatalogID
        }
        XCTAssertFalse(canonical.isEmpty)
        XCTAssertTrue(canonical.contains { $0.id == XAISpeechToText.liveCatalogID })
        XCTAssertEqual(DesktopLiveTranscription.liveModels.map(\.id), canonical.map(\.id))
        for model in canonical {
            let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: model.id))
            XCTAssertEqual(route, LiveTranscriptionRouting.route(for: model.id))
            let provider = try XCTUnwrap(DesktopLiveTranscription.provider(forID: model.id))
            XCTAssertEqual(provider.id, route.provider.rawValue)
            XCTAssertEqual(provider.apiKeyIdentifier, route.apiKeyIdentifier)
            XCTAssertEqual(provider.displayName, route.provider.displayName)
            XCTAssertEqual(provider.website, route.provider.apiKeyURL?.absoluteString)
            let client = DesktopLiveTranscription.makeClient(model: model.id, apiKey: "", makeConnection: { _ in
                fatalError("Constructing a client must not open a connection")
            })
            XCTAssertNotNil(client)
            if route.provider == .deepgram { XCTAssertTrue(client is DeepgramLiveClient) }
            if route.provider == .assemblyai { XCTAssertTrue(client is AssemblyAILiveClient) }
            if route.provider == .speechmatics { XCTAssertTrue(client is SpeechmaticsLiveClient) }
            if route.provider == .soniox { XCTAssertTrue(client is SonioxLiveClient) }
            if route.provider == .elevenlabs { XCTAssertTrue(client is ElevenLabsLiveClient) }
            if route.provider == .mistral { XCTAssertTrue(client is MistralVoxtralLiveClient) }
            if route.provider == .gladia { XCTAssertTrue(client is GladiaLiveClient) }
            if route.provider == .cartesia { XCTAssertTrue(client is CartesiaLiveClient) }
            if route.provider == .revai { XCTAssertTrue(client is RevAILiveClient) }
            if route.provider == .azure { XCTAssertTrue(client is AzureVoiceLiveClient) }
            if route.provider == .openai {
                XCTAssertTrue(client is OpenAIRealtimeLiveClient)
                XCTAssertEqual(route.sampleRate, OpenAIRealtimeProtocol.sampleRate)
            }
            if route.provider == .xai {
                XCTAssertEqual(model.id, XAISpeechToText.liveCatalogID)
                XCTAssertTrue(client is XAISpeechToTextLiveClient)
                XCTAssertEqual(route.sampleRate, 24_000)
            }
        }
        XCTAssertNil(DesktopLiveTranscription.route(forID: "deepgram/unknown-streaming"))
        XCTAssertNil(DesktopLiveTranscription.provider(forID: "deepgram/nova-3"))
        XCTAssertNil(DesktopLiveTranscription.route(forID: "openai/gpt-live-transcribe"))
    }

    /// Grok Voice shares the xAI provider prefix and credential with the
    /// dedicated speech-to-text stream but speaks a different protocol with no
    /// shared client, so admitting the provider wholesale would expose the
    /// wrong engine. Only the dedicated stream's identifier is a desktop route.
    func testGrokVoiceRouteStaysUnavailableInTheDesktopFactory() {
        let grokVoice = XAIVoiceModels.thinkFast2CatalogID
        XCTAssertEqual(LiveTranscriptionRouting.route(for: grokVoice)?.provider, .xai)
        XCTAssertFalse(DesktopLiveTranscription.liveModels.contains { $0.id == grokVoice })
        XCTAssertNil(DesktopLiveTranscription.route(forID: grokVoice))
        XCTAssertNil(DesktopLiveTranscription.provider(forID: grokVoice))
        XCTAssertNil(DesktopLiveTranscription.makeClient(model: grokVoice, apiKey: "", makeConnection: { _ in
            fatalError("An unavailable route must not open a connection")
        }))
        XCTAssertEqual(
            DesktopLiveTranscription.liveModels.filter { $0.id.hasPrefix("xai/") }.map(\.id),
            [XAISpeechToText.liveCatalogID]
        )
        XCTAssertEqual(DesktopLiveTranscription.provider(forID: XAISpeechToText.liveCatalogID)?.apiKeyIdentifier,
                       "xai.apiKey")
    }
}
