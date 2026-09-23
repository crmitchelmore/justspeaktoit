import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import XCTest

/// Invariants every desktop live route inherits, whichever provider it is. A
/// route in the projection must be a canonical catalogue entry, use the
/// credential the shared resolver names (the one its batch models already use),
/// run on the native capture as routed, and build its shared client without
/// opening anything. Gladia and Cartesia are named so the shared routes that
/// joined last are known to be covered, not merely filtered in.
final class DesktopLiveRouteInvariantTests: XCTestCase {
    /// The PCM rates native desktop capture produces for a live route.
    private let captureRates: Set<Int> = [16_000, 24_000]

    func testProjectionIsAnOrderedCanonicalSubsetIncludingGladiaAndCartesia() {
        let projected = DesktopLiveTranscription.liveModels.map(\.id)
        let admitted = Set(projected)
        XCTAssertEqual(admitted.count, projected.count, "Each route is projected once")
        XCTAssertEqual(
            ModelCatalog.liveTranscription.map(\.id).filter { admitted.contains($0) }, projected,
            "The projection filters the canonical catalogue in its order and copies nothing"
        )
        let providers = Set(projected.compactMap { DesktopLiveTranscription.route(forID: $0)?.provider })
        for provider in [LiveTranscriptionProviderID.gladia, .cartesia] {
            XCTAssertTrue(providers.contains(provider), provider.rawValue)
        }
    }

    func testEveryRouteUsesTheCanonicalCredentialItsBatchModelsShare() throws {
        let batchProviders = DesktopTranscription.batchModels.compactMap { DesktopTranscription.provider(for: $0.id) }
        for model in DesktopLiveTranscription.liveModels {
            let provider = try XCTUnwrap(DesktopLiveTranscription.provider(forID: model.id), model.id)
            guard case .apiKey(let identifier, let providerName) = ModelCredentialResolver.requirement(
                for: model.id, purpose: .liveTranscription
            ) else {
                XCTFail("\(model.id) needs a provider credential")
                continue
            }
            XCTAssertEqual(provider.apiKeyIdentifier, identifier, model.id)
            XCTAssertEqual(provider.displayName, providerName, model.id)
            for batch in batchProviders where batch.id == provider.id {
                XCTAssertEqual(batch.apiKeyIdentifier, identifier, "One saved key serves \(model.id) and batch")
            }
        }
        for shared in [LiveTranscriptionProviderID.gladia, .cartesia] {
            XCTAssertTrue(batchProviders.contains { $0.id == shared.rawValue }, "\(shared.rawValue) has batch models")
        }
    }

    func testEveryRouteRunsOnNativeCaptureAndBuildsAnInertFinalisingClient() throws {
        for model in DesktopLiveTranscription.liveModels {
            let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: model.id), model.id)
            XCTAssertEqual(route.sampleRate, route.provider.expectedSampleRate, model.id)
            XCTAssertTrue(captureRates.contains(route.sampleRate), "\(model.id) at \(route.sampleRate) Hz")
            let client = DesktopLiveTranscription.makeClient(
                model: model.id, apiKey: "synthetic", language: "fr_FR",
                makeConnection: { _ in fatalError("Constructing a client must not open a connection") }
            )
            XCTAssertNotNil(client, model.id)
            if let budget = client?.finalisationBudget {
                XCTAssertTrue(budget.isFinite && budget > 0, "\(model.id) declares a usable finish bound")
            }
        }
    }
}
