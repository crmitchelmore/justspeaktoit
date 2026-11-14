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
                let provider = String(model.id.prefix { $0 != "/" })
                XCTAssertTrue(CloudCatalogAndroidExport.transcriptionProviderIDs.contains(provider), model.id)
            }
        }
        XCTAssertEqual(models.first?.id, OpenAITranscriptionModels.gptTranscribeCatalogID)
    }

    /// Android offers every provider whose shared batch client iOS calls, plus OpenAI and Reson8.
    func testAndroidTranscriptionProvidersCoverEverySharedBatchClientProvider() {
        XCTAssertEqual(
            Set(CloudCatalogAndroidExport.transcriptionProviderIDs),
            BatchTranscriptionRouting.iosSharedClientProviderIDs.union(["openai", "reson8"])
        )
        let offered = Set(CloudCatalogAndroidExport.transcriptionModels.map(\.id))
        for option in ModelCatalog.batchTranscription where ModelRetirements.retirement(for: option.id) == nil {
            let provider = String(option.id.prefix { $0 != "/" })
            guard provider != "openai", CloudCatalogAndroidExport.transcriptionProviderIDs.contains(provider) else {
                continue
            }
            XCTAssertTrue(offered.contains(option.id), option.id)
        }
    }

    func testOnlyOpenAICompatibleModelsTakeAPromptAndOnlyReson8NamesItsLanguages() throws {
        let object = try JSONSerialization.jsonObject(with: CloudCatalogAndroidExport.json()) as? [String: Any]
        let models = try XCTUnwrap(object?["transcriptionModels"] as? [[String: Any]])
        for model in models {
            let id = try XCTUnwrap(model["catalogId"] as? String)
            let provider = try XCTUnwrap(model["provider"] as? String)
            if model["supportsPrompt"] as? Bool == true {
                XCTAssertTrue(CloudCatalogAndroidExport.openAICompatibleProviderIDs.contains(provider), id)
            }
            let codes = model["languageCodes"] as? [String]
            if let reson8 = Reson8Model(modelID: id) {
                XCTAssertEqual(codes, reson8.languageCodes.sorted(), id)
            } else {
                XCTAssertNil(codes, id)
            }
        }
        XCTAssertEqual(Set(models.compactMap { $0["catalogId"] as? String }.filter { $0.hasPrefix("reson8/") }),
                       Set(Reson8Model.allCases.map(\.batchID)))
    }

    func testDocumentCarriesCredentialsCleanupModelAndPrompt() throws {
        let object = try JSONSerialization.jsonObject(with: CloudCatalogAndroidExport.json()) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, 1)
        let providers = object?["providers"] as? [[String: String]]
        XCTAssertEqual(
            providers?.map { $0["credentialId"] },
            CloudCatalogAndroidExport.transcriptionProviderIDs.map(ProviderCredentialCatalogue.apiKeyIdentifier(for:))
                + ["openrouter.apiKey", "anthropic.apiKey", "google.apiKey"]
        )
        XCTAssertEqual(providers?.first?["credentialId"], "openai.apiKey")
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

    func testOpenRouterBrowserDescribesEveryOpenRouterCleanupModel() throws {
        let object = try JSONSerialization.jsonObject(with: CloudCatalogAndroidExport.json()) as? [String: Any]
        let browser = try XCTUnwrap(object?["openRouterBrowser"] as? [String: Any])
        XCTAssertEqual(browser["browseButtonTitle"] as? String, OpenRouterModelBrowserCatalog.browseButtonTitle)
        XCTAssertEqual(browser["useTitle"] as? String, "Use for cleanup")
        let cleanup = try XCTUnwrap(object?["cleanupModels"] as? [[String: String]])
        let openRouter = cleanup.filter { $0["provider"] == OpenRouterService.providerID }
            .compactMap { $0["selectionId"] }
        let rows = try XCTUnwrap(browser["cleanupModels"] as? [[String: Any]])
        XCTAssertEqual(rows.count, openRouter.count)
        XCTAssertEqual(Set(rows.compactMap { $0["selectionId"] as? String }), Set(openRouter))
        for row in rows {
            XCTAssertEqual(row["slug"] as? String, row["selectionId"] as? String)
            XCTAssertFalse((row["provider"] as? String ?? "").isEmpty)
            XCTAssertFalse((row["searchText"] as? [String] ?? []).isEmpty)
        }
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
