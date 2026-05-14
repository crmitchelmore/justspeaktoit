import XCTest

@testable import SpeakCore

final class ModelCatalogTests: XCTestCase {

    // MARK: - LatencyTier Ordering

    func testLatencyTier_ordering_instantIsFastest() {
        XCTAssertLessThan(LatencyTier.instant, .fast)
        XCTAssertLessThan(LatencyTier.fast, .medium)
        XCTAssertLessThan(LatencyTier.medium, .slow)
    }

    func testLatencyTier_displayName_isHumanReadable() {
        XCTAssertFalse(LatencyTier.instant.displayName.isEmpty)
        XCTAssertFalse(LatencyTier.slow.displayName.isEmpty)
        for tier in LatencyTier.allCases {
            XCTAssertFalse(tier.displayName.isEmpty, "\(tier) should have a display name")
        }
    }

    // MARK: - friendlyName

    func testFriendlyName_knownModel_returnsDisplayName() {
        guard let first = ModelCatalog.allOptions.first else {
            XCTFail("allOptions should not be empty")
            return
        }
        let name = ModelCatalog.friendlyName(for: first.id)
        XCTAssertEqual(name, first.displayName)
    }

    func testFriendlyName_unknownModel_returnsFriendlyFallback() {
        let name = ModelCatalog.friendlyName(for: "some-vendor/cool-model-v2")
        // Should strip vendor prefix and humanise
        XCTAssertFalse(name.contains("/"), "Friendly name should strip vendor prefix")
        XCTAssertFalse(name.isEmpty)
    }

    func testFriendlyName_downloadedLocalModels_returnsSpecificName() {
        XCTAssertEqual(
            ModelCatalog.friendlyName(for: "local/post-processing/qwen2.5-0.5b-instruct-q4"),
            "Qwen2.5 0.5B Instruct Q4"
        )
        XCTAssertEqual(
            ModelCatalog.friendlyName(
                for: "local/post-processing/huggingface/bartowski/qwen2.5-0.5b-instruct-gguf/qwen2.5-0.5b-instruct-q4-k-m.gguf"
            ),
            "Qwen2.5 0.5B Instruct Q4_K_M"
        )
        XCTAssertEqual(
            ModelCatalog.friendlyName(
                for: "local/whisperkit/huggingface/argmaxinc/whisperkit-coreml/openai-whisper-large-v3-turbo-954mb"
            ),
            "Openai Whisper Large V3 Turbo 954 MB"
        )
    }

    func testFriendlyName_emptyString_returnsNonEmpty() {
        let name = ModelCatalog.friendlyName(for: "")
        XCTAssertFalse(name.isEmpty, "Should return something even for empty identifier")
    }

    // MARK: - Pricing

    func testPricing_compactDisplay_formatsCorrectly() {
        let pricing = ModelCatalog.Pricing(promptPerMTokens: 0.15, completionPerMTokens: 0.60)
        XCTAssertEqual(pricing.compactDisplay, "$0.15/$0.60")
    }

    // MARK: - Catalog Integrity

    func testAllOptions_containsAllCategories() {
        let allCount = ModelCatalog.allOptions.count
        let sum = ModelCatalog.liveTranscription.count
            + ModelCatalog.batchTranscription.count
            + ModelCatalog.localTranscriptionOptions.count
            + ModelCatalog.postProcessing.count
        XCTAssertEqual(allCount, sum, "allOptions should be union of all category arrays")
    }

    func testAllOptions_haveUniqueIDsWithinCategories() {
        // IDs may be shared across categories (e.g. same model used for live + batch)
        // but should be unique within each category
        for (name, options) in [
            ("liveTranscription", ModelCatalog.liveTranscription),
            ("batchTranscription", ModelCatalog.batchTranscription),
            ("localTranscription", ModelCatalog.localTranscriptionOptions),
            ("postProcessing", ModelCatalog.postProcessing)
        ] {
            let ids = options.map(\.id)
            let uniqueIDs = Set(ids)
            XCTAssertEqual(
                ids.count,
                uniqueIDs.count,
                "\(name) should have unique model IDs"
            )
        }
    }

    func testAllOptions_haveNonEmptyDisplayNames() {
        for option in ModelCatalog.allOptions {
            XCTAssertFalse(option.displayName.isEmpty, "\(option.id) should have a display name")
        }
    }

    func testLiveTranscription_allHaveLatencyTiers() {
        for option in ModelCatalog.liveTranscription {
            XCTAssertNotNil(option.latencyTier, "\(option.id) should have a latency tier")
        }
    }

    func testLocalTranscription_isSeparateFromAppleSpeech() {
        XCTAssertFalse(ModelCatalog.localTranscription.isEmpty)
        for model in ModelCatalog.localTranscription {
            XCTAssertTrue(model.id.hasPrefix("local/"), "\(model.id) should use the downloaded local namespace")
            XCTAssertFalse(model.id.hasPrefix("apple/local/"), "\(model.id) should not be grouped with Apple Speech")
            XCTAssertFalse(model.supportsLiveStreaming, "\(model.id) should be explicit about offline-only support")
        }
    }

    func testModelRouting_distinguishesAppleSpeechFromDownloadedLocal() {
        XCTAssertEqual(ModelRouting.family(for: "apple/local/SFSpeechRecognizer"), .appleSpeech)
        XCTAssertEqual(ModelRouting.family(for: "local/whisperkit/tiny"), .downloadedLocal(engine: "whisperkit"))
    }

    func testModelRouting_treatsLocalCleanupAsPostProcessing() {
        XCTAssertEqual(
            ModelRouting.family(for: "local/post-processing/rules"),
            .postProcessing(provider: "local")
        )
    }

    func testPostProcessing_includesRecentFastCheapModels() {
        let ids = Set(ModelCatalog.postProcessing.map(\.id))

        XCTAssertTrue(ids.contains("openai/gpt-5-mini"))
        XCTAssertTrue(ids.contains("openai/gpt-5.4-mini"))
        XCTAssertTrue(ids.contains("openai/gpt-5.4-nano"))
        XCTAssertTrue(ids.contains("google/gemini-3.1-flash-lite"))
        XCTAssertTrue(ids.contains("qwen/qwen3.6-flash"))
    }

    func testPostProcessing_keepsLocalCleanupVisible() {
        let localCleanup = ModelCatalog.postProcessing.first {
            $0.id == "local/post-processing/rules"
        }

        XCTAssertNotNil(localCleanup)
        XCTAssertTrue(localCleanup?.tags.contains(.privacy) == true)
    }
}
