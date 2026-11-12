import XCTest
@testable import SpeakCore

final class OpenRouterCatalogOptionsTests: XCTestCase {
    func testModelsListOnlyOpenRouterRoutesInVendorOrder() {
        let options: [ModelCatalog.Option] = [
            .init(id: "openai/gpt-5-mini", displayName: "GPT-5 mini"),
            .init(id: "native/openai/gpt-5-mini", displayName: "GPT-5 mini"),
            .init(id: "anthropic/claude-haiku", displayName: "Claude Haiku"),
            .init(id: CleanupModelSelection.prefix + "openai/gpt-6", displayName: "GPT-6 (discovered)")
        ]
        let models = OpenRouterCatalogOptions.models(from: options, purpose: .postProcessing)
        XCTAssertEqual(models.map(\.id), [
            "anthropic/claude-haiku", "openai/gpt-5-mini", CleanupModelSelection.prefix + "openai/gpt-6"
        ])
    }

    func testDiscoveredVendorNamesMatchBundledProviderNames() {
        let bundled = ModelCatalog.Option(id: "google/gemini-3.8-flash", displayName: "Gemini")
        XCTAssertEqual(
            OpenRouterCatalogOptions.vendorName(forModelSlug: "google/new-transcriber"),
            OpenRouterCatalogOptions.provider(for: bundled, purpose: .batchTranscription)
        )
        XCTAssertEqual(OpenRouterCatalogOptions.vendorName(forModelSlug: "mistralai/voxtral"), "Mistral")
    }

    func testZeroPricesRequireListedZeroPricing() {
        XCTAssertFalse(OpenRouterCatalogOptions.hasZeroPrices(.init(id: "a/b", displayName: "Unpriced")))
        XCTAssertTrue(OpenRouterCatalogOptions.hasZeroPrices(.init(
            id: "a/b", displayName: "Free", pricing: .init(promptPerMTokens: 0, completionPerMTokens: 0)
        )))
        XCTAssertFalse(OpenRouterCatalogOptions.hasZeroPrices(.init(
            id: "a/b", displayName: "Paid", pricing: .init(promptPerMTokens: 0, completionPerMTokens: 0.4)
        )))
    }

    func testSlugAndModelPageStripSelectionPrefixesAndRejectMalformedSlugs() {
        XCTAssertEqual(OpenRouterCatalogOptions.modelSlug(for: CleanupModelSelection.prefix + "openai/gpt-6"),
                       "openai/gpt-6")
        XCTAssertEqual(OpenRouterCatalogOptions.modelSlug(for: OpenRouterTranscriptionSelection.prefix + "v/m"), "v/m")
        XCTAssertEqual(OpenRouterCatalogOptions.modelPageURL(for: "openai/gpt-5-mini")?.absoluteString,
                       "https://openrouter.ai/openai/gpt-5-mini")
        XCTAssertNil(OpenRouterCatalogOptions.modelPageURL(for: "no-vendor"))
        XCTAssertNil(OpenRouterCatalogOptions.modelPageURL(for: "a/b/c"))
    }

    func testBrowserFilterAppliesProviderPriceAndSearch() {
        var filter = OpenRouterBrowserFilter(query: " fast ")
        XCTAssertTrue(filter.matches(searchText: ["A fast model"], provider: "OpenAI", hasZeroPrices: false))
        XCTAssertFalse(filter.matches(searchText: ["Slow"], provider: "OpenAI", hasZeroPrices: false))
        filter = OpenRouterBrowserFilter(provider: "OpenAI", freeOnly: true)
        XCTAssertTrue(filter.matches(searchText: [], provider: "OpenAI", hasZeroPrices: true))
        XCTAssertFalse(filter.matches(searchText: [], provider: "OpenAI", hasZeroPrices: false))
        XCTAssertFalse(filter.matches(searchText: [], provider: "Google", hasZeroPrices: true))
    }
}
