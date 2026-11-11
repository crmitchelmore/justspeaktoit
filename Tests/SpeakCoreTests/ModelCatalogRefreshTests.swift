import XCTest

@testable import SpeakCore

final class ModelCatalogRefreshTests: XCTestCase {
    func testPostProcessing_includesGPT6RoutesWithVerifiedMetadata() throws {
        let expected: [String: (name: String, pricing: ModelCatalog.Pricing)] = [
            "openai/gpt-6-luna": ("GPT-6 Luna", .init(promptPerMTokens: 0.10, completionPerMTokens: 0.50)),
            "openai/gpt-6.1-sol": ("GPT-6.1 Sol", .init(promptPerMTokens: 2.0, completionPerMTokens: 10.0)),
            "openai/gpt-6-astra": ("GPT-6 Astra", .init(promptPerMTokens: 10.0, completionPerMTokens: 50.0))
        ]
        for (id, metadata) in expected {
            let matches = ModelCatalog.postProcessing.filter { $0.id == id }
            XCTAssertEqual(matches.count, 1, "Duplicate or missing \(id)")
            let option = try XCTUnwrap(matches.first)
            XCTAssertEqual(option.displayName, metadata.name)
            XCTAssertEqual(option.pricing, metadata.pricing)
            XCTAssertEqual(option.contextLength, 1_050_000)
            XCTAssertNil(option.estimatedLatencyMs, "No measured cleanup latency for \(id)")
            XCTAssertFalse(option.tags.contains(.fast))
            XCTAssertFalse(option.tags.contains(.quality))
            XCTAssertTrue(ModelCatalog.cloudPostProcessing.contains(option))
            XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel(id), id)
            XCTAssertEqual(ModelRouting.family(for: id), .postProcessing(provider: "openai"))
            XCTAssertEqual(
                ModelCredentialResolver.requirement(for: id, purpose: .postProcessing),
                .apiKey(identifier: "openrouter.apiKey", providerName: "OpenRouter")
            )
            XCTAssertFalse(ModelCatalog.liveTranscription.contains { $0.id == id })
            XCTAssertFalse(ModelCatalog.batchTranscription.contains { $0.id == id })
        }
    }

    func testPostProcessingRefresh_preservesExistingSelectionsAndDefault() {
        XCTAssertEqual(ModelCatalog.defaultPostProcessingModel, "openai/gpt-5.6-luna")
        for option in ModelCatalog.postProcessing {
            XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel(option.id), option.id)
        }
        for id in ["openai/gpt-5.6-luna", "openai/gpt-5.6-terra", "openai/gpt-5.6-sol"] {
            XCTAssertTrue(ModelCatalog.cloudPostProcessing.contains { $0.id == id })
            XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel(id), id)
        }
    }
}
