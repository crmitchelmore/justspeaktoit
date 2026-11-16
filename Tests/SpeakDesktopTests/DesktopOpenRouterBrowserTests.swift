import Foundation
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

/// The Windows and Linux OpenRouter browser's pages and details (#1618).
final class DesktopOpenRouterBrowserTests: XCTestCase {
    func testCleanupRowsSelectThePublishedSlotAndFollowThePickerSelection() throws {
        let free = DiscoveredCleanupModel(
            id: "openai/zephyr-free", name: "Zephyr Free", inputPrice: 0, outputPrice: 0, contextLength: 8_000
        )
        let remote = ModelCatalog.cloudPostProcessing + [free.option]
        let published = ModelPickerGrouping.flattened(remote, purpose: .postProcessing)
            + DesktopPostProcessing.localModels
        let browser = DesktopOpenRouterBrowser.cleanup(remote: remote, published: published)

        let expected = OpenRouterModelBrowserCatalog.cleanupItems(options: remote)
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(browser.items.map(\.id), expected.map(\.id))
        let freeSlot = try XCTUnwrap(browser.slot(for: free.option.id))
        XCTAssertEqual(published[Int(freeSlot)].id, free.option.id)
        XCTAssertTrue(published[Int(freeSlot)].displayName.hasPrefix("OpenRouter › Zephyr Free"))

        let page = browser.page(matching: OpenRouterBrowserFilter(), selectedSlot: freeSlot)
        XCTAssertEqual(page.rows.filter(\.selected).map(\.item.id), [free.option.id])
        XCTAssertEqual(page.status, "\(expected.count) of \(expected.count) models")
        XCTAssertEqual(page.title, "OpenRouter cleanup models")
        XCTAssertEqual(page.action, "Use for cleanup")
        XCTAssertEqual(page.selectedAction, "Selected for cleanup")
        XCTAssertEqual(page.providers, OpenRouterModelBrowserCatalog.providers(in: expected))
        XCTAssertTrue(page.rows.allSatisfy { !$0.details.isEmpty && $0.automationID.hasPrefix("openRouterBrowser.") })
    }

    func testFiltersNarrowRowsAndExplainAnEmptyResult() {
        let free = DiscoveredCleanupModel(
            id: "openai/zephyr-free", name: "Zephyr Free", inputPrice: 0, outputPrice: 0, contextLength: nil
        )
        let remote = ModelCatalog.cloudPostProcessing + [free.option]
        let browser = DesktopOpenRouterBrowser.cleanup(remote: remote, published: remote)

        let freeOnly = browser.page(matching: OpenRouterBrowserFilter(freeOnly: true), selectedSlot: -1)
        XCTAssertEqual(freeOnly.rows.map(\.item.id), [free.option.id])
        XCTAssertEqual(freeOnly.status, "1 of \(browser.items.count) models")
        let name = OpenRouterCatalogOptions.provider(for: free.option, purpose: .postProcessing)
        let provider = browser.page(matching: OpenRouterBrowserFilter(provider: name), selectedSlot: -1)
        XCTAssertTrue(provider.rows.allSatisfy { $0.item.provider == name })
        XCTAssertTrue(provider.rows.contains { $0.item.id == free.option.id })
        let query = browser.page(matching: OpenRouterBrowserFilter(query: "zephyr free"), selectedSlot: -1)
        XCTAssertEqual(query.rows.map(\.item.id), [free.option.id])
        let none = browser.page(matching: OpenRouterBrowserFilter(query: "no such model"), selectedSlot: -1)
        XCTAssertTrue(none.rows.isEmpty)
        XCTAssertEqual(none.status, OpenRouterModelBrowserCatalog.emptyResults)
    }

    func testItemsWithoutAPickerSlotAreNotOffered() {
        let remote = ModelCatalog.cloudPostProcessing
        let items = OpenRouterModelBrowserCatalog.cleanupItems(options: remote)
        let kept = items.prefix(1).map(\.id)
        let browser = DesktopOpenRouterBrowser(purpose: .cleanup, items: items, slots: [kept[0]: 4])
        XCTAssertEqual(browser.items.map(\.id), kept)
        XCTAssertEqual(browser.page(matching: OpenRouterBrowserFilter(), selectedSlot: 4).rows.map(\.slot), [4])
    }

    func testDetailsShowPricingOrSayItIsUnlisted() throws {
        let discovered = DiscoveredCleanupModel(
            id: "openai/gpt-future", name: "GPT Future", inputPrice: 0.1, outputPrice: 0.5, contextLength: 1_000
        )
        let priced = try XCTUnwrap(OpenRouterModelBrowserCatalog.cleanupItems(options: [discovered.option]).first)
        let details = DesktopOpenRouterBrowser.details(for: priced, purpose: .cleanup)
        XCTAssertTrue(details.contains("Provider: OpenAI"), details)
        XCTAssertTrue(details.contains("Context limit: 1000 tokens"), details)
        XCTAssertTrue(details.contains("Input / output: \(try XCTUnwrap(priced.pricing).displayName) tokens"))
        XCTAssertTrue(details.contains(OpenRouterModelBrowserCatalog.pricingCaveat))
        XCTAssertTrue(details.contains(OpenRouterModelBrowserCatalog.unqualifiedWarning))
        XCTAssertTrue(details.hasSuffix(OpenRouterModelBrowserCatalog.routeNote(for: .cleanup)))

        let listed = try XCTUnwrap(OpenRouterModelBrowserCatalog.transcriptionItems(
            bundled: [], discovered: [audioModel("vendor/stt", pricing: ["request": "0.1", "audio": "0.002"])]
        ).first)
        let audio = DesktopOpenRouterBrowser.details(for: listed, purpose: .transcription)
        XCTAssertTrue(audio.contains("audio: 0.002\nrequest: 0.1\n" + DesktopOpenRouterBrowser.listedPricesNote))
        XCTAssertFalse(audio.contains(OpenRouterModelBrowserCatalog.unqualifiedWarning))

        let unlisted = try XCTUnwrap(OpenRouterModelBrowserCatalog.transcriptionItems(
            bundled: [], discovered: [audioModel("vendor/unpriced")]
        ).first)
        XCTAssertTrue(DesktopOpenRouterBrowser.details(for: unlisted, purpose: .transcription)
            .contains(OpenRouterModelBrowserCatalog.pricingUnlisted))
    }

    func testTranscriptionRowsSelectVisibleRemoteBatchSlotsOnly() throws {
        var slots = DesktopModelSlots(live: DesktopLiveTranscription.liveModels)
        let discovered = [try audioModel("vendor/stt-one", name: "STT One")]
        try slots.update(discovered: discovered, retaining: [])
        let browser = DesktopOpenRouterBrowser.transcription(discovered: discovered, slots: slots)

        let id = discovered[0].transcriptionSelectionID
        let slot = try XCTUnwrap(browser.slot(for: id))
        let entry = slots.entries[Int(slot)]
        XCTAssertEqual(entry.option.id, id)
        XCTAssertFalse(entry.isLive || entry.isLocal)
        XCTAssertTrue(slots.visibleIndices.contains(Int(slot)))
        XCTAssertTrue(browser.items.contains { $0.id == id })
        let page = browser.page(matching: OpenRouterBrowserFilter(query: "STT One"), selectedSlot: slot)
        XCTAssertEqual(page.rows.map(\.item.id), [id])
        XCTAssertEqual(page.rows.first?.selected, true)
        XCTAssertEqual(page.rows.first?.url, "https://openrouter.ai/vendor/stt-one")
        XCTAssertEqual(page.action, "Use for transcription")
    }

    func testAutomationIDsAreStableAndSafe() {
        XCTAssertEqual(
            DesktopOpenRouterBrowser.automationID(for: "openrouter/cleanup/openai/gpt-5.1-mini", purpose: .cleanup),
            "openRouterBrowser.cleanup.openai-gpt-5-1-mini"
        )
        XCTAssertEqual(
            DesktopOpenRouterBrowser.automationID(
                for: OpenRouterTranscriptionSelection.identifier(for: "vendor/stt"), purpose: .transcription
            ),
            "openRouterBrowser.transcription.vendor-stt"
        )
    }

    private func audioModel(
        _ id: String, name: String = "Model", pricing: [String: String] = [:]
    ) throws -> OpenRouterAudioModel {
        let json: [String: Any] = [
            "id": id, "name": name, "description": "Speech model",
            "architecture": ["input_modalities": ["audio"], "output_modalities": ["transcription"]],
            "pricing": pricing
        ]
        return try JSONDecoder().decode(OpenRouterAudioModel.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
