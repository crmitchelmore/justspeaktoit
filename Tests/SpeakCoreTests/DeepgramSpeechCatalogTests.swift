import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DeepgramSpeechCatalogTests: XCTestCase {
    func testFluxSelectionAndLegacyMigration_remainsCompatible() {
        let selection = DeepgramSpeechCatalog.resolvedSelection(modelID: " flux ", voiceID: "deepgram/flux-haley-en")
        XCTAssertEqual(selection.model.id, "flux")
        XCTAssertEqual(selection.voice.id, "flux-haley-en")
        XCTAssertEqual(DeepgramSpeechCatalog.resolvedSelection(modelID: "flux", voiceID: "asteria").voice.id,
                       "flux-kit-en")
        XCTAssertEqual(DeepgramSpeechCatalog.resolvedSelection(modelID: nil, voiceID: "flux-kit-en").model.id,
                       "flux")
        XCTAssertEqual(DeepgramSpeechCatalog.resolvedSelection(modelID: "aura-2", voiceID: "flux-kit-en").voice.id,
                       "aura-2-asteria-en")
        for voice in DeepgramTTSCatalog.voices {
            let migrated = DeepgramSpeechCatalog.resolvedSelection(modelID: voice.model.id, voiceID: voice.id)
            XCTAssertEqual(migrated.voice.id, voice.id)
        }
        XCTAssertEqual(Set(DeepgramSpeechCatalog.voices.map(\.id)).count, DeepgramSpeechCatalog.voices.count)
        XCTAssertEqual(DeepgramSpeechCatalog.voices(forModelID: "flux").count, 13)
    }

    func testTransportRoutesFluxAndAura_usesOwnEndpoints() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = DeepgramTTSAPI(session: session)
        for (model, path) in [("flux-kit-en", "/v2/speak"), ("aura-2-asteria-en", "/v1/speak")] {
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, path)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token fixture")
                XCTAssertEqual(request.httpMethod, "POST")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "model" }?.value, model)
                return .status(200, Data([1, 2, 3]), url: request.url!)
            }
            let data = try await api.synthesize(text: "Hello", apiKey: "fixture",
                                               queryItems: [URLQueryItem(name: "model", value: model)])
            XCTAssertEqual(data, Data([1, 2, 3]))
        }
        StubURLProtocol.reset()
    }
}
