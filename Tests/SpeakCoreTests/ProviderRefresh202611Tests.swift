import XCTest
@testable import SpeakCore

/// Weekly provider check, 11 November 2026: Grok Voice 3.0, ElevenLabs Scribe v3,
/// MAI-Transcribe-2 GA and the repriced rates.
final class ProviderRefresh202611Tests: XCTestCase {
    func testGrokVoice2Selection_movesToGrokVoice3WithTheSameAPI() throws {
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel(XAIVoiceModels.thinkFast2CatalogID),
            XAIVoiceModels.voice3CatalogID
        )
        XCTAssertFalse(ModelCatalog.liveTranscription.contains { $0.id == XAIVoiceModels.thinkFast2CatalogID })
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: XAIVoiceModels.voice3CatalogID))
        XCTAssertEqual(route.provider, .xai)
        XCTAssertEqual(route.apiModelName, "grok-voice-3.0")
    }

    func testScribeV3_isOfferedInBothModesWithoutMovingScribeV2() throws {
        XCTAssertTrue(ModelCatalog.batchTranscription.contains { $0.id == ModelCatalog.elevenLabsScribeV3BatchID })
        XCTAssertTrue(ModelCatalog.liveTranscription.contains { $0.id == ModelCatalog.elevenLabsScribeV3LiveID })
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel(ModelCatalog.elevenLabsScribeV2BatchID),
            ModelCatalog.elevenLabsScribeV2BatchID
        )
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel("elevenlabs/scribe-v2-streaming"),
            "elevenlabs/scribe-v2-streaming"
        )
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: ModelCatalog.elevenLabsScribeV3LiveID))
        XCTAssertEqual(route.provider, .elevenlabs)
        XCTAssertEqual(route.apiModelName, "scribe_v3_live")
        XCTAssertEqual(
            LiveTranscriptionRouting.route(for: "elevenlabs/scribe-v2-streaming")?.apiModelName,
            "scribe_v2_realtime"
        )
        XCTAssertTrue(ModelCatalog.liveCapabilities(for: ModelCatalog.elevenLabsScribeV3LiveID).supportsLanguageHint)
    }

    func testRealtimeKeyterms_respectFiftyTermsOfTwentyCharacters() throws {
        let words = (0..<80).map { "term\($0)" } + [String(repeating: "x", count: 30)]
        for model in ["scribe_v2_realtime", "scribe_v3_live"] {
            let url = try XCTUnwrap(ElevenLabsLiveProtocol.webSocketURL(
                modelID: model, language: nil, sampleRate: 16_000, keywords: words))
            let terms = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                .filter { $0.name == "keyterms" }.compactMap(\.value)
            XCTAssertEqual(terms.count, 50, model)
            XCTAssertTrue(terms.allSatisfy { $0.count <= 20 }, model)
        }
    }

    func testMAITranscribeBatch_isGenerallyAvailableWhileStreamingStaysPreview() {
        let batch = AzureTranscriptionModels.batchOptions.filter { $0.id != AzureTranscriptionModels.fast }
        XCTAssertFalse(batch.isEmpty)
        XCTAssertTrue(batch.allSatisfy { !$0.displayName.contains("Preview") })
        XCTAssertTrue(AzureTranscriptionModels.liveOptions.first {
            $0.id == AzureTranscriptionModels.mai2Streaming
        }?.displayName.contains("Preview") == true)
    }

    private func hourlyCost(_ modelID: String) -> Double {
        TranscriptionPricing.estimatedCostUSD(modelID: modelID, durationSeconds: 3_600)
            .map { NSDecimalNumber(decimal: $0).doubleValue } ?? -1
    }

    func testRepricedRates_matchProviderPricingPages() {
        XCTAssertEqual(hourlyCost(ModelCatalog.elevenLabsScribeV3BatchID), 0.20, accuracy: 1e-9)
        XCTAssertEqual(hourlyCost(ModelCatalog.elevenLabsScribeV2BatchID), 0.20, accuracy: 1e-9)
        XCTAssertEqual(hourlyCost(ModelCatalog.elevenLabsScribeV3LiveID), 0.22, accuracy: 1e-9)
        XCTAssertEqual(hourlyCost("elevenlabs/scribe-v2-streaming"), 0.22, accuracy: 1e-9)
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: "deepgram/nova-3-streaming"),
                       Decimal(string: "0.0077"))
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: "deepgram/flux-general-en-streaming"),
                       Decimal(string: "0.0077"))
        XCTAssertEqual(DeepgramTTSAPI.costPerThousandCharacters, Decimal(string: "0.030"))
        XCTAssertEqual(DeepgramTTSAPI.aura1CostPerThousandCharacters, Decimal(string: "0.015"))
        XCTAssertEqual(DeepgramTTSAPI.costPerThousandCharacters(forVoiceID: "deepgram/aura-asteria-en"),
                       Decimal(string: "0.015"))
        XCTAssertEqual(DeepgramTTSAPI.costPerThousandCharacters(forVoiceID: "aura-2-asteria-en"),
                       Decimal(string: "0.030"))
        XCTAssertNil(DeepgramTTSAPI.costPerThousandCharacters(forVoiceID: "deepgram/flux-hannah"))
    }

    func testClaude55CleanupEntries_routeThroughOpenRouter() {
        for id in ["anthropic/claude-haiku-5.5", "anthropic/claude-sonnet-5.5"] {
            XCTAssertTrue(ModelCatalog.cloudPostProcessing.contains { $0.id == id }, id)
            XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel(id), id)
            XCTAssertEqual(
                ModelCredentialResolver.requirement(for: id, purpose: .postProcessing),
                .apiKey(identifier: "openrouter.apiKey", providerName: "OpenRouter")
            )
        }
    }
}
