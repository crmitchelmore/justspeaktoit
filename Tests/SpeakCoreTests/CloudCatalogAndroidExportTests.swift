import Foundation
import XCTest

@testable import SpeakCore

/// The Android app's cloud catalogue is a committed JSON asset; this keeps it identical to SpeakCore.
final class CloudCatalogAndroidExportTests: XCTestCase {
    private var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets/cloud_catalog.json")
    }

    func testAndroidAssetMatchesCatalogue() throws {
        let expected = try CloudCatalogAndroidExport.json()
        if ProcessInfo.processInfo.environment["UPDATE_CLOUD_CATALOG_ANDROID"] == "1" {
            try FileManager.default.createDirectory(
                at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try expected.write(to: assetURL)
        }
        let committed = try Data(contentsOf: assetURL)
        XCTAssertEqual(
            committed, expected,
            "android/app/src/main/assets/cloud_catalog.json is stale. Regenerate with "
                + "UPDATE_CLOUD_CATALOG_ANDROID=1 swift test --filter CloudCatalogAndroidExportTests"
        )
    }

    func testExportedModelsAreCurrentDirectBatchModelsOfAndroidProviders() {
        let models = CloudCatalogAndroidExport.transcriptionModels
        XCTAssertFalse(models.isEmpty)
        let batchIDs = Set(ModelCatalog.batchTranscription.map(\.id))
        for model in models {
            XCTAssertTrue(batchIDs.contains(model.id), model.id)
            XCTAssertNil(ModelRetirements.retirement(for: model.id), model.id)
            if model.id.hasPrefix("openai/") {
                XCTAssertTrue(OpenAITranscriptionModels.directBatchModelIDs.contains(model.id), model.id)
            } else {
                XCTAssertTrue(model.id.hasPrefix("groq/"), model.id)
            }
        }
        XCTAssertEqual(models.first?.id, OpenAITranscriptionModels.gptTranscribeCatalogID)
    }

    func testLiveModelsAreCurrentRoutesOfAndroidLiveProviders() throws {
        let models = CloudCatalogAndroidExport.liveTranscriptionModels
        let expected = ModelCatalog.liveTranscription.filter { option in
            guard let route = LiveTranscriptionRouting.route(for: option.id) else { return false }
            return [.deepgram, .assemblyai, .openai].contains(route.provider)
                && ModelRetirements.retirement(for: option.id) == nil
        }
        XCTAssertEqual(models.map(\.id), expected.map(\.id))
        XCTAssertTrue(models.map(\.id).contains(AssemblyAIModels.universal36ProStreamingID))
        XCTAssertTrue(models.map(\.id).contains(OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID))

        let object = try JSONSerialization.jsonObject(with: CloudCatalogAndroidExport.json()) as? [String: Any]
        let exported = try XCTUnwrap(object?["liveTranscriptionModels"] as? [[String: Any]])
        for entry in exported {
            let id = try XCTUnwrap(entry["catalogId"] as? String)
            let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: id))
            let capabilities = ModelCatalog.liveCapabilities(for: id)
            XCTAssertEqual(entry["apiName"] as? String, route.apiModelName, id)
            XCTAssertEqual(entry["sampleRate"] as? Int, route.sampleRate, id)
            XCTAssertEqual((entry["languageField"] as? String)?.isEmpty, !capabilities.supportsLanguageHint, id)
            XCTAssertEqual(
                entry["postStopFinalizeBudgetMs"] as? Int,
                Int((capabilities.postStopFinalizeBudget * 1000).rounded()), id
            )
        }
    }

    func testDocumentCarriesCredentialsCleanupModelAndPrompt() throws {
        let object = try JSONSerialization.jsonObject(with: CloudCatalogAndroidExport.json()) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, 1)
        let providers = object?["providers"] as? [[String: String]]
        XCTAssertEqual(
            providers?.map { $0["credentialId"] },
            [
                "openai.apiKey", "groq.apiKey", "deepgram.apiKey", "assemblyai.apiKey",
                "openrouter.apiKey", "anthropic.apiKey", "google.apiKey", "mistral.apiKey"
            ]
        )
        let cleanup = object?["cleanup"] as? [String: String]
        XCTAssertEqual(cleanup?["model"], ModelCatalog.defaultPostProcessingModel)
        XCTAssertEqual(cleanup?["systemPrompt"], TranscriptCleanupPolicy.systemPrompt())
    }

    func testCleanupModelsAreNativeRoutesThenOpenRouterSlugs() throws {
        let object = try JSONSerialization.jsonObject(with: CloudCatalogAndroidExport.json()) as? [String: Any]
        let models = try XCTUnwrap(object?["cleanupModels"] as? [[String: String]])
        let offered = Set(ModelCatalog.cloudPostProcessing.map(\.id))
        let native = NativeTextModels.postProcessing.filter { offered.contains($0.id) }
        XCTAssertEqual(Array(models.prefix(native.count)).map { $0["selectionId"] }, native.map(\.id))
        for model in models.dropFirst(native.count) {
            XCTAssertEqual(model["provider"], OpenRouterService.providerID)
            XCTAssertEqual(model["apiName"], model["selectionId"])
        }
        let ids = Set(models.compactMap { $0["selectionId"] })
        XCTAssertTrue(ids.contains(ModelCatalog.defaultPostProcessingModel))
        XCTAssertTrue(models.allSatisfy { !($0["selectionId"] ?? "").hasPrefix("local/") })
    }

    func testDocumentCarriesLanguagesAndVocabularyPromptRules() throws {
        let object = try JSONSerialization.jsonObject(with: CloudCatalogAndroidExport.json()) as? [String: Any]
        let languages = try XCTUnwrap(object?["languages"] as? [[String: String]])
        XCTAssertEqual(languages.map { $0["id"] }, TranscriptionLanguageCatalog.options.map(\.id))
        XCTAssertEqual(languages.first?["id"], TranscriptionLanguageCatalog.automaticIdentifier)
        let prompt = try XCTUnwrap(object?["keywordPrompt"] as? [String: Int])
        XCTAssertEqual(prompt["maximumBytes"], TranscriptionKeywordPolicy.promptMaximumCharacters)
        XCTAssertEqual(prompt["maximumTerms"], TranscriptionKeywordPolicy.promptMaximumTerms)
        let models = try XCTUnwrap(object?["transcriptionModels"] as? [[String: Any]])
        for model in models {
            let apiName = try XCTUnwrap(model["apiName"] as? String)
            let expected = OpenAITranscriptionModels.supportsBatchPrompt(apiName)
            XCTAssertEqual(model["supportsPrompt"] as? Bool, expected, apiName)
        }
    }
}
