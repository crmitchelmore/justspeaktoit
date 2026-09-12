import Foundation
import XCTest

@testable import SpeakCore

final class TranscriptionPricingTests: XCTestCase {
    func testOnDeviceModels_areFree() {
        for id in ["local/whisperkit/tiny", AppleLocalModels.speechTranscriberModelID, "apple/local/Dictation"] {
            XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: id), .zero, id)
            XCTAssertEqual(TranscriptionPricing.estimatedCostUSD(modelID: id, durationSeconds: 90), .zero, id)
        }
    }

    func testKnownRates_matchPublishedModeSpecificPrices() {
        // The public September rates distinguish file and streaming modes.
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: "deepgram/nova-3"), Decimal(string: "0.0043"))
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: "deepgram/enhanced"), Decimal(string: "0.0165"))
        XCTAssertEqual(
            TranscriptionPricing.pricePerMinuteUSD(modelID: "modulate/velma-2-stt-streaming"),
            Decimal(string: "0.06")! / 60
        )
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: "openai/whisper-1"), Decimal(string: "0.006"))
    }

    func testStreamingAndFileRatesRemainDistinct() {
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: "deepgram/nova-3-streaming"),
                       Decimal(string: "0.0048"))
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: "elevenlabs/scribe_v2"),
                       Decimal(string: "0.22")! / 60)
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: "elevenlabs/scribe-v2-streaming"),
                       Decimal(string: "0.39")! / 60)
    }

    func testExactIdsWinOverProviderPrefixes() {
        XCTAssertEqual(
            TranscriptionPricing.pricePerMinuteUSD(modelID: AssemblyAIModels.universal35ProStreamingID),
            Decimal(string: "0.15")! / 60
        )
        XCTAssertEqual(
            TranscriptionPricing.pricePerMinuteUSD(modelID: AssemblyAIModels.universal35ProBatchID),
            Decimal(string: "0.27")! / 60
        )
    }

    func testUnknownModels_haveNoPrice() {
        XCTAssertNil(TranscriptionPricing.pricePerMinuteUSD(modelID: "xai/grok-stt-streaming"))
        XCTAssertNil(TranscriptionPricing.pricePerMinuteUSD(modelID: "nobody/model"))
        XCTAssertNil(TranscriptionPricing.estimatedCostUSD(modelID: "nobody/model", durationSeconds: 60))
    }

    func testEstimate_scalesWithDurationAndIgnoresNonPositiveDurations() {
        XCTAssertEqual(
            TranscriptionPricing.estimatedCostUSD(modelID: "openai/whisper-1", durationSeconds: 30),
            Decimal(string: "0.003")
        )
        XCTAssertNil(TranscriptionPricing.estimatedCostUSD(modelID: "openai/whisper-1", durationSeconds: 0))
    }

    func testFormatted_keepsSubCentPrecision() {
        XCTAssertEqual(TranscriptionPricing.formatted(.zero), "$0")
        XCTAssertEqual(TranscriptionPricing.formatted(Decimal(string: "0.00123456")!), "$0.0012")
        XCTAssertEqual(TranscriptionPricing.formatted(Decimal(string: "0.0456")!), "$0.046")
        XCTAssertEqual(TranscriptionPricing.formatted(Decimal(string: "1.5")!), "$1.5")
    }

    /// Every cloud transcription model in the catalogue either has a price or
    /// is on the documented no-public-rate list, so a new catalogue entry
    /// prompts a pricing decision instead of silently showing no cost.
    func testEveryCatalogueTranscriptionModel_isEitherPricedOrKnownUnpriced() {
        // No public per-minute list price at the last review: token-billed
        // realtime sessions, previews, and providers that only quote per hour
        // on request. Adding a rate for one of these must also remove it here.
        let knownUnpriced: Set<String> = [
            "openai/gpt-realtime-whisper-streaming",
            "openai/gpt-live-transcribe-streaming",
            "openai/gpt-transcribe",
            "openai/gpt-4o-transcribe-diarize",
            "openai/gpt-4o-audio-preview-2024-12-17",
            "google/gemini-3.5-transcribe",
            "google/gemini-3.5-transcribe-live",
            "mistral/voxtral-mini-transcribe-realtime-2602-streaming",
            "cartesia/ink-2-streaming",
            "cartesia/ink-whisper",
            "speechmatics/enhanced-streaming",
            "speechmatics/enhanced",
            "speechmatics/standard",
            "apple/local/Dictation"
        ]
        let catalogue = ModelCatalog.liveTranscription + ModelCatalog.batchTranscription
        for option in catalogue {
            let prefix = option.id.split(separator: "/").first.map(String.init) ?? ""
            if ["xai", "meta"].contains(prefix) || knownUnpriced.contains(option.id) {
                XCTAssertTrue(
                    TranscriptionPricing.pricePerMinuteUSD(modelID: option.id) == nil
                        || TranscriptionPricing.isFree(option.id),
                    "\(option.id) is listed as unpriced but has a rate; move it out of the list"
                )
            } else {
                XCTAssertNotNil(TranscriptionPricing.pricePerMinuteUSD(modelID: option.id), "\(option.id) needs a rate")
            }
        }
    }
}
