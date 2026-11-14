import Foundation
import XCTest
@testable import SpeakCore

/// The shared OpenRouter browser rules, checked against `Tests/Fixtures/openrouter-browser`,
/// which Android's `OpenRouterCleanupDiscoveryTest` and `OpenRouterBrowserTest` also read.
final class OpenRouterModelBrowserCatalogTests: XCTestCase {
    func testCleanupDiscoveryKeepsOnlyTheFixturesTrustedModels() throws {
        let fixture = try object("cleanup-discovery.json")
        let response = try JSONSerialization.data(withJSONObject: try XCTUnwrap(fixture["response"]))
        let models = try JSONDecoder().decode(CleanupModelResponse.self, from: response).data
        let expected = try XCTUnwrap(fixture["expected"] as? [[String: Any]])
        XCTAssertEqual(models.map(\.id), expected.compactMap { $0["id"] as? String })
        for (model, row) in zip(models, expected) {
            XCTAssertEqual(model.name, row["name"] as? String, model.id)
            XCTAssertEqual(model.inputPrice, (row["inputPrice"] as? NSNumber)?.doubleValue, model.id)
            XCTAssertEqual(model.outputPrice, (row["outputPrice"] as? NSNumber)?.doubleValue, model.id)
            XCTAssertEqual(model.contextLength, (row["contextLength"] as? NSNumber)?.intValue, model.id)
        }
    }

    func testFilterMatchesTheSharedFixtureCases() throws {
        let fixture = try object("filter-cases.json")
        let items = try XCTUnwrap(fixture["items"] as? [[String: Any]])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        for testCase in cases {
            let filter = OpenRouterBrowserFilter(
                query: testCase["query"] as? String ?? "",
                provider: testCase["provider"] as? String ?? "",
                freeOnly: testCase["freeOnly"] as? Bool ?? false
            )
            let matched = items.filter { item in
                filter.matches(
                    searchText: item["searchText"] as? [String] ?? [],
                    provider: item["provider"] as? String ?? "",
                    hasZeroPrices: item["hasZeroPrices"] as? Bool ?? false
                )
            }
            XCTAssertEqual(matched.compactMap { $0["id"] as? String }, testCase["expected"] as? [String],
                           "\(testCase)")
        }
    }

    func testAudioZeroPricesNeedEveryListedPriceToBeZero() throws {
        let fixture = try object("filter-cases.json")
        let cases = try XCTUnwrap(fixture["audioZeroPrices"] as? [[String: Any]])
        for testCase in cases {
            let model = try audioModel("vendor/stt", pricing: testCase["pricing"] as? [String: String] ?? [:])
            XCTAssertEqual(OpenRouterAudioFilter.hasZeroPrices(model), testCase["zero"] as? Bool, "\(testCase)")
        }
    }

    func testCleanupItemsListOnlyOpenRouterRoutesWithDetails() throws {
        let discovered = DiscoveredCleanupModel(
            id: "openai/gpt-future", name: "GPT Future", inputPrice: 0.1, outputPrice: 0.5, contextLength: 1_000
        )
        let saved = try XCTUnwrap(CleanupModelSelection.retainedOption("openrouter/cleanup/openai/gpt-saved"))
        let items = OpenRouterModelBrowserCatalog.cleanupItems(
            options: ModelCatalog.cloudPostProcessing + [discovered.option, saved]
        )
        XCTAssertFalse(items.contains { NativeTextModels.isNative($0.id) })
        XCTAssertTrue(items.contains { $0.id == ModelCatalog.defaultPostProcessingModel && $0.origin == .bundled })

        let item = try XCTUnwrap(items.first { $0.id == discovered.selectionID })
        XCTAssertEqual(item.origin, .discovered)
        XCTAssertTrue(item.isUnqualifiedDiscovery)
        XCTAssertEqual(item.slug, "openai/gpt-future")
        XCTAssertEqual(item.provider, "OpenAI")
        XCTAssertEqual(item.pricing, ModelCatalog.Pricing(promptPerMTokens: 0.1, completionPerMTokens: 0.5))
        XCTAssertEqual(item.contextLength, 1_000)
        XCTAssertEqual(item.selectionLabel, "OpenRouter › GPT Future (discovered)")
        XCTAssertEqual(item.modelPageURL?.absoluteString, "https://openrouter.ai/openai/gpt-future")
        XCTAssertEqual(item.subtitle, "openai/gpt-future · $0.10/$0.50 / 1M")

        let retained = try XCTUnwrap(items.first { $0.id == saved.id })
        XCTAssertEqual(retained.origin, .discovered)
        XCTAssertNil(retained.pricing)
        XCTAssertFalse(retained.hasZeroPrices)

        let filtered = OpenRouterModelBrowserCatalog.filtered(
            items, by: OpenRouterBrowserFilter(query: "gpt future", provider: "OpenAI")
        )
        XCTAssertEqual(filtered.map(\.id), [discovered.selectionID])
        let providers = OpenRouterModelBrowserCatalog.providers(in: items)
        XCTAssertEqual(providers, Array(Set(providers)).sorted { $0.lowercased() < $1.lowercased() })
        XCTAssertTrue(providers.contains("OpenAI"))
    }

    func testTranscriptionItemsListBundledFirstThenLiveSpeechToTextByName() throws {
        let zulu = try audioModel("vendor/zulu-stt", name: "Zulu STT", pricing: ["audio": "0"])
        let alpha = try audioModel("vendor/alpha-stt", name: "Alpha STT")
        let speech = try audioModel("vendor/voice", name: "Voice", outputs: ["speech"])
        let bundled = ModelCatalog.batchTranscription.filter {
            ModelPickerGrouping.isOpenRouter($0.id, purpose: .batchTranscription)
        }
        let items = OpenRouterModelBrowserCatalog.transcriptionItems(
            bundled: ModelCatalog.batchTranscription, discovered: [zulu, speech, alpha, zulu]
        )
        XCTAssertEqual(items.prefix(bundled.count).map(\.origin), Array(repeating: .bundled, count: bundled.count))
        XCTAssertEqual(Set(items.prefix(bundled.count).map(\.id)), Set(bundled.map(\.id)))
        XCTAssertEqual(items.dropFirst(bundled.count).map(\.id), [
            "openrouter/transcription/vendor/alpha-stt", "openrouter/transcription/vendor/zulu-stt"
        ])
        let live = try XCTUnwrap(items.last)
        XCTAssertEqual(live.slug, "vendor/zulu-stt")
        XCTAssertEqual(live.listedPrices, ["audio": "0"])
        XCTAssertTrue(live.hasZeroPrices)
        XCTAssertFalse(live.isUnqualifiedDiscovery)
        XCTAssertEqual(live.subtitle, "Discovered · vendor/zulu-stt")
        XCTAssertEqual(live.selectionLabel, "OpenRouter › Zulu STT")
        XCTAssertEqual(OpenRouterModelBrowserCatalog.filtered(
            items, by: OpenRouterBrowserFilter(query: "alpha", freeOnly: true)
        ), [])
    }

    func testMissingTranscriptionSelectionNeedsALoadedCatalogue() throws {
        let alpha = try audioModel("vendor/alpha-stt", name: "Alpha STT")
        let saved = OpenRouterTranscriptionSelection.identifier(for: "vendor/gone")
        XCTAssertEqual(OpenRouterModelBrowserCatalog.missingTranscriptionSelection(
            saved, discovered: [alpha], catalogueLoaded: true
        ), "vendor/gone")
        XCTAssertNil(OpenRouterModelBrowserCatalog.missingTranscriptionSelection(
            saved, discovered: [alpha], catalogueLoaded: false
        ))
        XCTAssertNil(OpenRouterModelBrowserCatalog.missingTranscriptionSelection(
            alpha.transcriptionSelectionID, discovered: [alpha], catalogueLoaded: true
        ))
        XCTAssertNil(OpenRouterModelBrowserCatalog.missingTranscriptionSelection(
            "native/openai/gpt-transcribe", discovered: [], catalogueLoaded: true
        ))
    }

    func testDiscoveryEndpointsAndSharedCopy() {
        XCTAssertEqual(OpenRouterModelBrowserCatalog.cleanupModelsURL.absoluteString,
                       "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(OpenRouterModelBrowserCatalog.transcriptionModelsURL.absoluteString,
                       "https://openrouter.ai/api/v1/models?output_modalities=transcription")
        XCTAssertEqual(OpenRouterModelBrowserCatalog.browseButtonTitle, "Browse OpenRouter models…")
        XCTAssertTrue(OpenRouterModelBrowserCatalog.streamingNote.hasPrefix("OpenRouter models can't stream"))
    }

    private func object(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/openrouter-browser/\(name)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func audioModel(
        _ id: String, name: String = "Model", outputs: [String] = ["transcription"], pricing: [String: String] = [:]
    ) throws -> OpenRouterAudioModel {
        let json: [String: Any] = [
            "id": id, "name": name, "description": "Speech model",
            "architecture": ["input_modalities": ["audio"], "output_modalities": outputs],
            "pricing": pricing
        ]
        return try JSONDecoder().decode(OpenRouterAudioModel.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
