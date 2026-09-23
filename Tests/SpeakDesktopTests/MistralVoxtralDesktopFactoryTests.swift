import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import XCTest

/// The native desktop projection and factory for the canonical Voxtral route.
/// Only public API is imported here, so both initializers are checked as the
/// exported surface the Apple and Windows hosts compile against.
final class MistralVoxtralDesktopFactoryTests: XCTestCase {
    private let liveID = MistralVoxtralRealtime.liveCatalogID

    func testRouteIsProjectedFromTheCanonicalCatalogueAndRouting() throws {
        XCTAssertTrue(ModelCatalog.liveTranscription.contains { $0.id == liveID })
        XCTAssertTrue(DesktopLiveTranscription.liveModels.contains { $0.id == liveID })
        let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: " \(liveID)\n"))
        XCTAssertEqual(route, LiveTranscriptionRouting.route(for: liveID))
        XCTAssertEqual(route.provider, .mistral)
        XCTAssertEqual(route.apiModelName, MistralVoxtralRealtime.apiModelID)
        XCTAssertEqual(route.sampleRate, LiveTranscriptionProviderID.mistral.expectedSampleRate)
        let provider = try XCTUnwrap(DesktopLiveTranscription.provider(forID: liveID))
        XCTAssertEqual(provider.id, LiveTranscriptionProviderID.mistral.rawValue)
        XCTAssertEqual(provider.displayName, "Mistral")
        XCTAssertEqual(provider.apiKeyIdentifier, "mistral.apiKey")
        XCTAssertEqual(provider.website, LiveTranscriptionProviderID.mistral.apiKeyURL?.absoluteString)
    }

    func testFactoryBuildsTheSharedClientOverTheInjectedTransportWithCanonicalMetadata() throws {
        let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: liveID))
        let factory = AssemblyAISocketFactory()
        let built = DesktopLiveTranscription.makeClient(
            model: liveID, apiKey: "desktop-key", makeConnection: { factory.make($0) }
        )
        let client = try XCTUnwrap(built as? MistralVoxtralLiveClient)
        XCTAssertEqual(client.finalShape, .cumulativeTranscript)
        XCTAssertTrue(client.finishFlushesBufferedAudio)
        XCTAssertEqual(client.finalisationBudget, MistralVoxtralRealtime.finishBudget)
        XCTAssertTrue(factory.sockets.isEmpty, "Constructing a client opens nothing")
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        let request = try XCTUnwrap(factory.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer desktop-key")
        let url = try XCTUnwrap(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [URLQueryItem(name: "model", value: route.apiModelName)])
        let socket = factory.sockets[0]
        socket.open()
        socket.sessionCreated()
        let session = try XCTUnwrap(socket.sessionUpdate?["session"] as? [String: Any])
        let format = try XCTUnwrap(session["audio_format"] as? [String: Any])
        XCTAssertEqual(format["sample_rate"] as? Int, route.sampleRate)
        XCTAssertEqual(format["encoding"] as? String, "pcm_s16le")
        client.cancel()
        XCTAssertEqual(socket.cancels, 1)
    }

    func testSavedLanguageSelectionsAddNoWireField() throws {
        XCTAssertFalse(ModelCatalog.liveCapabilities(for: liveID).supportsLanguageHint)
        XCTAssertFalse(DesktopLiveTranscription.languageHintModelIDs.contains(liveID))
        for language in ["fr_FR", "en", TranscriptionLanguageCatalog.automaticIdentifier, "", nil] as [String?] {
            let factory = AssemblyAISocketFactory()
            let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
                model: liveID, apiKey: "k", language: language, makeConnection: { factory.make($0) }
            ))
            client.start(onTranscript: { _, _ in }, onError: { _ in })
            let url = try XCTUnwrap(factory.requests.first?.url)
            let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
            XCTAssertEqual(names, ["model"], "\(String(describing: language))")
            factory.sockets[0].open()
            factory.sockets[0].sessionCreated()
            let update = try XCTUnwrap(factory.sockets[0].controls.first)
            XCTAssertFalse(update.contains("language"), "\(String(describing: language)) reached the wire")
            client.cancel()
        }
    }

    func testNativeCaptureKeepsOneHundredMillisecondFrames() throws {
        XCTAssertEqual(DesktopLiveTranscription.captureFrameMilliseconds(forID: liveID), 100)
        let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: liveID))
        XCTAssertEqual(route.sampleRate * 100 / 1_000 * 2, 3_200, "One native frame is 3,200 bytes of mono PCM16")
    }

    func testBatchUnknownAndUnimplementedRoutesStayUnavailable() {
        let batch = ModelCatalog.batchTranscriptionOptions(forProvider: "mistral").map(\.id)
        XCTAssertFalse(batch.isEmpty)
        for identifier in batch + ["mistral/unknown-streaming"] {
            XCTAssertNil(DesktopLiveTranscription.route(forID: identifier), identifier)
            XCTAssertNil(DesktopLiveTranscription.provider(forID: identifier), identifier)
            XCTAssertEqual(DesktopLiveTranscription.captureFrameMilliseconds(forID: identifier), 100, identifier)
        }
        // Gladia's shared client joined the projection alongside Voxtral, and
        // GladiaDesktopFactoryTests covers it positively; the rest stay out.
        let unimplemented: Set<LiveTranscriptionProviderID> = [
            .apple, .azure, .cartesia, .google, .modulate, .meta, .revai
        ]
        for model in ModelCatalog.liveTranscription {
            guard let route = LiveTranscriptionRouting.route(for: model.id),
                  unimplemented.contains(route.provider) else { continue }
            XCTAssertFalse(DesktopLiveTranscription.liveModels.contains { $0.id == model.id }, model.id)
            XCTAssertNil(DesktopLiveTranscription.makeClient(model: model.id, apiKey: "k", makeConnection: { _ in
                fatalError("An unavailable route must not open a connection")
            }), model.id)
        }
    }

    func testLegacyAndInjectedInitializersAreExported() {
        let legacy: (String, String, Int, URLSession) -> MistralVoxtralLiveClient =
            MistralVoxtralLiveClient.init(apiKey:model:sampleRate:session:)
        let injected: (
            String, String, Int, @escaping MistralVoxtralLiveClient.ConnectionFactory,
            @escaping MistralVoxtralLiveClient.Scheduler
        ) -> MistralVoxtralLiveClient = MistralVoxtralLiveClient.init(apiKey:model:sampleRate:makeConnection:schedule:)
        let apple = legacy("k", MistralVoxtralRealtime.apiModelID, 16_000, .shared)
        let desktop = injected("k", MistralVoxtralRealtime.apiModelID, 16_000, { _ in
            fatalError("Constructing a client must not open a connection")
        }, { _, _ in })
        XCTAssertEqual(apple.finalShape, desktop.finalShape)
        XCTAssertEqual(apple.finalisationBudget, desktop.finalisationBudget)
        XCTAssertEqual(apple.finishFlushesBufferedAudio, desktop.finishFlushesBufferedAudio)
        apple.cancel()
        desktop.cancel()
    }
}
