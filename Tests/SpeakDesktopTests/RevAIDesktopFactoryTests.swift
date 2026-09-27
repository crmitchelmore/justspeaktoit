import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

/// The canonical Rev.ai live route on desktop hosts: admitted from the shared
/// catalogue and routing and built as the shared client over the host's
/// transport. `RevAIDesktopSessionTests` covers the shared desktop session.
final class RevAIDesktopFactoryTests: XCTestCase {
    private var canonical: ModelCatalog.Option? {
        ModelCatalog.liveTranscription.first { LiveTranscriptionRouting.route(for: $0.id)?.provider == .revai }
    }

    func testCanonicalRouteIsAdmittedWithoutCopiedMetadata() throws {
        let option = try XCTUnwrap(canonical)
        // The persisted identifier stays exactly as shipped.
        XCTAssertEqual(option.id, "revai/machine-v2-streaming")
        let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: " \(option.id) \n"))
        XCTAssertEqual(route, LiveTranscriptionRouting.route(for: option.id))
        XCTAssertEqual(route.sampleRate, LiveTranscriptionProviderID.revai.expectedSampleRate)
        let projected = DesktopLiveTranscription.liveModels.filter {
            LiveTranscriptionRouting.route(for: $0.id)?.provider == .revai
        }
        XCTAssertEqual(projected.map(\.id), [option.id])
        XCTAssertEqual(projected.first?.displayName, option.displayName)

        let provider = try XCTUnwrap(DesktopLiveTranscription.provider(forID: option.id))
        XCTAssertEqual(provider.id, LiveTranscriptionProviderID.revai.rawValue)
        XCTAssertEqual(provider.displayName, LiveTranscriptionProviderID.revai.displayName)
        XCTAssertEqual(provider.apiKeyIdentifier, "revai.apiKey", "One saved token serves live and batch")
        XCTAssertEqual(provider.website, LiveTranscriptionProviderID.revai.apiKeyURL?.absoluteString)
        XCTAssertTrue(DesktopLiveTranscription.languageHintModelIDs.contains(option.id))
        XCTAssertEqual(DesktopLiveTranscription.captureFrameMilliseconds(forID: option.id), 100)

        let client = DesktopLiveTranscription.makeClient(
            model: option.id, apiKey: "key", language: "fr_FR", makeConnection: { _ in
                fatalError("Constructing a client must not open a connection")
            }
        )
        XCTAssertTrue(client is RevAILiveClient)
        XCTAssertEqual(client?.finalShape, .standaloneSegments)
        XCTAssertEqual(client?.finishFlushesBufferedAudio, true)
        XCTAssertEqual(client?.finalisationBudget, RevAIStreaming.finishBudget)
    }

    func testRequestCarriesTheSelectionAsRevAIsOwnCodeAndTheTokenOnlyInTheQuery() throws {
        let option = try XCTUnwrap(canonical)
        let system = RevAIStreaming.languageCode(for: nil)
        let cases: [(selection: String?, code: String?)] = [
            ("fr_FR", "fr"), ("zh_CN", "cmn"), ("ru_RU", nil), ("automatic", system), (nil, system)
        ]
        for (selection, code) in cases {
            let factory = AssemblyAISocketFactory()
            let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
                model: option.id, apiKey: " synthetic ", language: selection, makeConnection: { factory.make($0) }
            ))
            client.start(onTranscript: { _, _ in }, onError: { XCTFail("Unexpected error: \($0)") })
            let request = try XCTUnwrap(factory.requests.first)
            let url = try XCTUnwrap(request.url)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let label = String(describing: selection)
            XCTAssertEqual(items.first { $0.name == "language" }?.value, code, label)
            XCTAssertEqual(items.first { $0.name == "access_token" }?.value, "synthetic", label)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), label)
            XCTAssertFalse(items.contains { $0.value == selection }, "\(label): the stored selection is never sent")
            client.cancel()
        }
    }
}
