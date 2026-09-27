import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

/// The canonical Cartesia live route on desktop hosts: admitted from the shared
/// catalogue and routing and built as the shared client over the host's
/// transport. `CartesiaDesktopSessionTests` covers the shared desktop session.
final class CartesiaDesktopFactoryTests: XCTestCase {
    private var canonical: ModelCatalog.Option? {
        ModelCatalog.liveTranscription.first { LiveTranscriptionRouting.route(for: $0.id)?.provider == .cartesia }
    }

    func testCanonicalRouteIsAdmittedWithoutCopiedMetadata() throws {
        let option = try XCTUnwrap(canonical)
        // The persisted identifier and API model name stay exactly as shipped.
        XCTAssertEqual(option.id, "cartesia/ink-2-streaming")
        let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: " \(option.id) \n"))
        XCTAssertEqual(route, LiveTranscriptionRouting.route(for: option.id))
        XCTAssertEqual(route.apiModelName, "ink-2")
        XCTAssertEqual(route.sampleRate, LiveTranscriptionProviderID.cartesia.expectedSampleRate)
        let projected = DesktopLiveTranscription.liveModels.filter {
            LiveTranscriptionRouting.route(for: $0.id)?.provider == .cartesia
        }
        XCTAssertEqual(projected.map(\.id), [option.id])
        XCTAssertEqual(projected.first?.displayName, option.displayName)

        let provider = try XCTUnwrap(DesktopLiveTranscription.provider(forID: option.id))
        XCTAssertEqual(provider.id, LiveTranscriptionProviderID.cartesia.rawValue)
        XCTAssertEqual(provider.displayName, LiveTranscriptionProviderID.cartesia.displayName)
        XCTAssertEqual(provider.apiKeyIdentifier, LiveTranscriptionProviderID.cartesia.apiKeyIdentifier)
        XCTAssertEqual(provider.website, LiveTranscriptionProviderID.cartesia.apiKeyURL?.absoluteString)
        XCTAssertFalse(DesktopLiveTranscription.languageHintModelIDs.contains(option.id))
        XCTAssertEqual(DesktopLiveTranscription.captureFrameMilliseconds(forID: option.id), 100)

        let client = DesktopLiveTranscription.makeClient(
            model: option.id, apiKey: "key", language: "fr_FR", makeConnection: { _ in
                fatalError("Constructing a client must not open a connection")
            }
        )
        XCTAssertTrue(client is CartesiaLiveClient)
        XCTAssertEqual(client?.finalShape, .standaloneSegments)
        XCTAssertEqual(client?.finishFlushesBufferedAudio, true)
        XCTAssertEqual(client?.finalisationBudget, CartesiaLiveClient.finishBudget)
    }

    func testSelectedLanguageNeverReachesTheRequest() throws {
        let option = try XCTUnwrap(canonical)
        let factory = AssemblyAISocketFactory()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: option.id, apiKey: "synthetic", language: "fr_FR", makeConnection: { factory.make($0) }
        ))
        client.start(onTranscript: { _, _ in }, onError: { XCTFail("Unexpected error: \($0)") })
        defer { client.cancel() }
        let url = try XCTUnwrap(factory.requests.first?.url)
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
        XCTAssertEqual(names, ["model", "encoding", "sample_rate", "cartesia_version"])
        XCTAssertEqual(factory.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
    }
}
