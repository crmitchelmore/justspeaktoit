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
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: "elevenlabs/scribe_v2_medical"),
                       Decimal(string: "0.22")! / 60)
    }

    func testExactIdsWinOverProviderPrefixes() {
        // MAI-Transcribe-2 is far cheaper than the Azure fallback rate.
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: AzureTranscriptionModels.mai2),
                       Decimal(string: "0.10")! / 60)
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: AzureTranscriptionModels.mai2Streaming),
                       Decimal(string: "0.54")! / 60)
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: AzureTranscriptionModels.fast),
                       Decimal(string: "1.00")! / 60)
        XCTAssertEqual(
            TranscriptionPricing.pricePerMinuteUSD(modelID: AssemblyAIModels.universal36ProStreamingID),
            Decimal(string: "0.45")! / 60
        )
        XCTAssertEqual(
            TranscriptionPricing.pricePerMinuteUSD(modelID: AssemblyAIModels.universal35ProBatchID),
            Decimal(string: "0.21")! / 60
        )
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: AssemblyAIModels.universal2BatchID),
                       Decimal(string: "0.15")! / 60)
    }

    func testUnknownModels_haveNoPrice() {
        XCTAssertNil(TranscriptionPricing.pricePerMinuteUSD(modelID: "xai/grok-stt-streaming"))
        XCTAssertNil(TranscriptionPricing.pricePerMinuteUSD(modelID: "nobody/model"))
        XCTAssertNil(TranscriptionPricing.estimatedCostUSD(modelID: "nobody/model", durationSeconds: 60))
    }

    func testAlibabaModels_haveNoRegionBlindOrTokenBlindMinuteEstimate() {
        for id in AlibabaSpeechModels.allIDs {
            XCTAssertNil(TranscriptionPricing.pricePerMinuteUSD(modelID: id), id)
            XCTAssertNil(TranscriptionPricing.estimatedCostUSD(modelID: id, durationSeconds: 60), id)
            XCTAssertFalse(TranscriptionPricing.isFree(id), id)
        }
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
    /// is on the documented no-fixed-estimate list, so a new catalogue entry
    /// prompts a pricing decision instead of silently showing no cost.
    func testEveryCatalogueTranscriptionModel_isEitherPricedOrKnownUnpriced() {
        // No reliable model-only per-minute estimate at the last review:
        // token-billed sessions, regional prices, previews, and rates quoted
        // on request. Adding a rate for one of these must also remove it here.
        let knownUnpriced: Set<String> = [
            // Fun-ASR has different published Beijing/Singapore USD rates;
            // Omni is input/output-token billed. This model-only API cannot
            // infer the workspace region or generated output token count.
            // https://www.alibabacloud.com/help/en/model-studio/model-pricing
            // Decision and exact regional rates: Docs/alibaba-speech.md.
            AlibabaSpeechModels.funFlash,
            AlibabaSpeechModels.funLive,
            AlibabaSpeechModels.qwen35,
            AlibabaSpeechModels.qwen38,
            "openai/gpt-realtime-whisper-streaming",
            "openai/gpt-live-transcribe-streaming",
            "openai/gpt-transcribe",
            "openai/gpt-4o-transcribe-diarize",
            "openai/gpt-audio",
            "thinkingmachines/inkling",
            "thinkingmachines/inkling-small",
            "google/gemini-3.1-pro-preview",
            "mistralai/voxtral-small-24b-2507",
            "google/gemini-3.8-flash",
            "google/gemini-3.5-flash-lite",
            "google/gemini-3.5-transcribe",
            "google/gemini-3.5-transcribe-live",
            "mistral/voxtral-mini-transcribe-realtime-2602-streaming",
            "cartesia/ink-2-streaming",
            "cartesia/ink-whisper",
            "speechmatics/enhanced-streaming",
            "speechmatics/enhanced",
            "speechmatics/standard",
            // Reson8's engine is server-selected; no verified public USD quote.
            FileSpeechProvider.reson8.modelID,
            FileSpeechProvider.reson8LiveID,
            // StepAudio 3 publishes 2.8 CNY/hour, not a USD conversion.
            FileSpeechProvider.stepfun.modelID,
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
