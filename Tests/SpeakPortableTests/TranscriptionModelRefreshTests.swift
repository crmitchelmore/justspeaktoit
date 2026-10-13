import Foundation
import XCTest
@testable import SpeakCore

final class TranscriptionModelRefreshTests: XCTestCase {
    private let hostedModels = [
        "thinkingmachines/inkling",
        "thinkingmachines/inkling-small",
        "thinkingmachines/inkling:free",
        "thinkingmachines/inkling-small:free",
        "google/gemini-3.1-pro-preview",
        "mistralai/voxtral-small-24b-2507",
        "google/gemini-3.8-flash",
        "google/gemini-3.5-flash-lite"
    ]

    func testHostedAudioChatChoicesKeepTheirRouteKeyAndSavedIdentifier() throws {
        for identifier in hostedModels {
            let option = try XCTUnwrap(ModelCatalog.batchTranscription.first { $0.id == identifier }, identifier)
            XCTAssertTrue(option.displayName.contains("(OpenRouter)"))
            XCTAssertTrue(OpenRouterInlineAudioTranscriptionClient.batchCatalogIDs.contains(identifier))
            XCTAssertNil(OpenRouterTranscriptionSelection.modelID(from: identifier))
            XCTAssertFalse(OpenAITranscriptionModels.directBatchModelIDs.contains(identifier))
            XCTAssertFalse(GeminiTranscribeModels.directBatchModelIDs.contains(identifier))
            XCTAssertEqual(
                ModelCredentialResolver.requirement(for: identifier, purpose: .batchTranscription),
                .apiKey(identifier: "openrouter.apiKey", providerName: "OpenRouter")
            )
            XCTAssertEqual(ModelCatalog.normalizedBatchTranscriptionModel(" \(identifier) "), identifier)
            XCTAssertFalse(ModelCatalog.liveTranscription.contains { $0.id == identifier })
            XCTAssertFalse(ModelCatalog.localTranscription.contains { $0.id == identifier })
        }
        XCTAssertEqual(ModelCatalog.defaultBatchTranscriptionModel, "google/gemini-3.1-flash-lite")
        XCTAssertTrue(ModelCatalog.defaultOnDeviceLiveTranscriptionModel.hasPrefix("apple/"))
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel("thinkingmachines/custom:free"),
            "thinkingmachines/custom:free"
        )
    }

    func testAssemblyAIUpgradeIsStreamingOnlyAndPreservesBatchFallback() throws {
        let upgraded = AssemblyAIModels.universal36ProStreamingID
        let currentBatch = AssemblyAIModels.universal35ProBatchID
        for identifier in AssemblyAIModels.legacyUniversal3StreamingIDs {
            XCTAssertEqual(ModelCatalog.normalizedLiveTranscriptionModel(identifier), upgraded)
            XCTAssertEqual(LiveTranscriptionSelection(remoteModel: identifier).remoteModel, upgraded)
        }
        XCTAssertEqual(ModelCatalog.normalizedBatchTranscriptionModel(currentBatch), currentBatch)
        XCTAssertTrue(ModelCatalog.batchTranscription.contains { $0.id == currentBatch })
        XCTAssertFalse(ModelCatalog.batchTranscription.contains { $0.id == "assemblyai/universal-3-6-pro" })
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: upgraded))
        XCTAssertEqual(route.apiModelName, "universal-3-6-pro")
        XCTAssertEqual(route.apiKeyIdentifier, "assemblyai.apiKey")
        XCTAssertTrue(route.isSupportedOnIOS)
        XCTAssertEqual(
            AssemblyAIBatchClient().mapSpeechModels(from: currentBatch),
            ["universal-3-5-pro", "universal-2"]
        )
        let url = try XCTUnwrap(AssemblyAIStreamingRequest.url(
            endpoint: .europe, apiKey: "fixture-key", sampleRate: 16_000
        ))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)).queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "speech_model" }?.value, "universal-3-6-pro")
        XCTAssertNil(query.first { $0.name == "format_turns" })
        XCTAssertEqual(query.first { $0.name == "min_turn_silence" }?.value, "560")
    }

    func testDocumentedSonioxRetirementsMigrateWithoutResettingCustomModels() {
        for version in [3, 4] {
            XCTAssertEqual(
                ModelCatalog.normalizedBatchTranscriptionModel("soniox/stt-async-v\(version)"),
                "soniox/stt-async-v5"
            )
            XCTAssertEqual(
                ModelCatalog.normalizedLiveTranscriptionModel("soniox/stt-rt-v\(version)-streaming"),
                "soniox/stt-rt-v5-streaming"
            )
        }
        XCTAssertEqual(ModelCatalog.normalizedBatchTranscriptionModel("soniox/custom"), "soniox/custom")
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel("soniox/custom-streaming"), "soniox/custom-streaming"
        )
    }

    func testRatesUsePublishedAssemblyAIPricesAndDoNotGuessAudioChatMinutes() {
        XCTAssertEqual(
            TranscriptionPricing.pricePerMinuteUSD(modelID: AssemblyAIModels.universal36ProStreamingID),
            Decimal(string: "0.45")! / 60
        )
        XCTAssertEqual(
            TranscriptionPricing.pricePerMinuteUSD(modelID: AssemblyAIModels.universal35ProBatchID),
            Decimal(string: "0.21")! / 60
        )
        XCTAssertEqual(
            TranscriptionPricing.pricePerMinuteUSD(modelID: AssemblyAIModels.universal2BatchID),
            Decimal(string: "0.15")! / 60
        )
        XCTAssertNil(TranscriptionPricing.pricePerMinuteUSD(modelID: "assemblyai/custom"))
        XCTAssertEqual(
            TranscriptionPricing.pricePerMinuteUSD(modelID: "mistral/voxtral-mini-latest"),
            Decimal(string: "0.003")
        )
        for identifier in hostedModels {
            if identifier.hasSuffix(":free") {
                XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: identifier), .zero)
            } else {
                XCTAssertNil(TranscriptionPricing.pricePerMinuteUSD(modelID: identifier))
            }
        }

    }

    func testUnavailableAudioPreviewMovesToAnAvailableOpenRouterAudioChatRoute() {
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel("openai/gpt-4o-audio-preview-2024-12-17"),
            "openai/gpt-audio"
        )
        XCTAssertTrue(OpenRouterInlineAudioTranscriptionClient.batchCatalogIDs.contains("openai/gpt-audio"))
        XCTAssertFalse(OpenAITranscriptionModels.directBatchModelIDs.contains("openai/gpt-audio"))
        for identifier in ["openai/whisper-1", "openai/gpt-4o-mini-transcribe", "openai/gpt-4o-transcribe-diarize"] {
            XCTAssertEqual(ModelCatalog.normalizedBatchTranscriptionModel(identifier), identifier)
        }
    }

    func testModulateModelsAPIKeepsTheCredentialAndUsesItsCurrentOrigin() {
        XCTAssertEqual(ModulateTranscriptionService.baseURL.absoluteString, "https://platform.modulate.ai")
        XCTAssertEqual(
            ModulateTranscriptionService.streamingURL.absoluteString,
            "wss://platform.modulate.ai/api/velma-2-stt-streaming"
        )
        XCTAssertEqual(LiveTranscriptionProviderID.modulate.streamingHost, "platform.modulate.ai")
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: "modulate/velma-2-stt-batch", purpose: .batchTranscription
            ),
            .apiKey(identifier: "modulate.apiKey", providerName: "Modulate")
        )
    }
}
