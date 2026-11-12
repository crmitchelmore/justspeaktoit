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

    func testPostProcessingRefresh_preservesCurrentSelectionsAndDefault() {
        XCTAssertEqual(ModelCatalog.defaultPostProcessingModel, "openai/gpt-6-luna")
        for option in ModelCatalog.postProcessing {
            XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel(option.id), option.id)
            XCTAssertNil(CleanupModelRemovals.removal(for: option.id), "\(option.id) is both offered and removed")
        }
    }

    func testRemovedCleanupModels_moveToAnOfferedSuccessorOnTheSameRoute() {
        let offered = Set(ModelCatalog.cloudPostProcessing.map(\.id))
        for removal in CleanupModelRemovals.all {
            let successor = ModelCatalog.normalizedPostProcessingModel(removal.id)
            XCTAssertEqual(successor, removal.successorID)
            XCTAssertTrue(offered.contains(successor), "\(removal.id) moves to unoffered \(successor)")
            XCTAssertEqual(NativeTextModels.route(for: removal.id)?.provider,
                           NativeTextModels.route(for: successor)?.provider,
                           "\(removal.id) changes route")
            XCTAssertEqual(
                ModelCredentialResolver.requirement(for: removal.id, purpose: .postProcessing),
                ModelCredentialResolver.requirement(for: successor, purpose: .postProcessing),
                "\(removal.id) needs a different key from \(successor)"
            )
            // Gemini 2.5 Flash is still a batch transcription entry with its own name.
            if !ModelCatalog.allOptions.contains(where: { $0.id == removal.id }) {
                XCTAssertEqual(ModelCatalog.friendlyName(for: removal.id), removal.displayName)
            }
        }
        XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel("openai/gpt-5.6-luna"), "openai/gpt-6-luna")
        XCTAssertEqual(
            ModelCatalog.normalizedPostProcessingModel("native/anthropic/claude-sonnet-4-6"),
            "native/anthropic/claude-sonnet-5-5"
        )
    }

    func testRemovedCleanupModel_inSavedProfileOrRequestUsesSuccessor() throws {
        let json = #"{"id":"6F1A2B3C-0000-4000-8000-000000000001","name":"Mail","polishModelID":"openai/gpt-5.4"}"#
        let profile = try JSONDecoder().decode(DictationProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.polishModelID, "openai/gpt-6.1-sol")

        let request = OpenRouterChatRequest(
            model: "openai/gpt-5.6-terra", temperature: 0, messages: [], stream: nil, maxTokens: nil
        )
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "openai/gpt-6.1-terra")
    }
}
