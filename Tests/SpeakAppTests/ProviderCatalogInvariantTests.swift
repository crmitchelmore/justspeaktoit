import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

/// Guards the single-source invariant between ModelCatalog and the providers:
/// the pickers read the catalogue while routing reads each provider's
/// `supportedModels()`, so a model declared by a provider but missing from the
/// catalogue (or vice versa) silently breaks one of the two.
final class ProviderCatalogInvariantTests: XCTestCase {
    func testAllProviderSupportedModels_areSubsetOfModelCatalog() async {
        let registry = TranscriptionProviderRegistry.shared
        let catalogIDs = Set(
            (ModelCatalog.batchTranscription + ModelCatalog.liveTranscription).map(\.id)
        )

        for metadata in await registry.allProviders() {
            guard let provider = await registry.provider(withID: metadata.id) else {
                XCTFail("Registry lists \(metadata.id) but returns no provider for it")
                continue
            }
            for model in provider.supportedModels() {
                XCTAssertTrue(
                    catalogIDs.contains(model.id),
                    "\(metadata.id) supports \(model.id), which is missing from ModelCatalog"
                )
            }
        }
    }

    func testAllProviderSupportedModels_routeBackToTheirProvider() async {
        let registry = TranscriptionProviderRegistry.shared

        for metadata in await registry.allProviders() {
            guard let provider = await registry.provider(withID: metadata.id) else { continue }
            for model in provider.supportedModels() {
                let routed = await registry.provider(forModel: model.id)
                XCTAssertEqual(
                    routed?.metadata.id,
                    metadata.id,
                    "\(model.id) should route to the \(metadata.id) provider"
                )
            }
        }
    }

    /// The other direction. Both tests above start from `supportedModels()`, so a
    /// catalogue entry that nothing claims passes them while the picker offers a
    /// model that can never be dispatched.
    ///
    /// Live models are dispatched by `LiveTranscriptionRouting`, not by the batch
    /// provider registry, so that is what the invariant checks.
    func testEveryLiveCatalogModel_resolvesToARoute() {
        for model in ModelCatalog.liveTranscription {
            XCTAssertNotNil(
                LiveTranscriptionRouting.route(for: model.id),
                "ModelCatalog lists live model \(model.id), which LiveTranscriptionRouting cannot route"
            )
        }
    }

    /// Batch models are dispatched by `TranscriptionManager.transcribeFile`, which
    /// tries the provider registry and otherwise falls back to the OpenRouter batch
    /// client. Both paths are legitimate, so the invariant is that every catalogue
    /// entry is *deliberately* on one of them: anything the registry does not claim
    /// has to appear in `openRouterRoutedBatchModels` below.
    ///
    /// A stale catalogue entry therefore fails this test until someone classifies
    /// it, instead of silently reaching OpenRouter with a model it cannot serve.
    func testEveryBatchCatalogModel_isClaimedByAProviderOrExplicitlyOpenRouterRouted() async {
        let registry = TranscriptionProviderRegistry.shared

        for model in ModelCatalog.batchTranscription {
            // Apple entries transcribe on-device via ModelRouting.appleSpeech.
            if ModelRouting.family(for: model.id) == .appleSpeech { continue }

            if await registry.provider(forModel: model.id) != nil { continue }

            XCTAssertTrue(
                Self.openRouterRoutedBatchModels.contains(model.id),
                """
                ModelCatalog lists batch model \(model.id), but no registered provider claims it \
                and it is not listed as OpenRouter-routed. Either add it to the owning provider's \
                supportedModels() or to openRouterRoutedBatchModels.
                """
            )
        }
    }

    /// Multimodal batch models served through OpenRouter rather than a dedicated
    /// provider. Their catalogue display names carry the "(OpenRouter)" suffix.
    private static let openRouterRoutedBatchModels: Set<String> = [
        "google/gemini-2.0-flash-001",
        "google/gemini-2.0-flash-lite-001",
        "openai/gpt-4o-audio-preview-2024-12-17"
    ]
}
