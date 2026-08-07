import XCTest

@testable import SpeakCore

// swiftlint:disable:next type_body_length
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
            ModelCatalog.friendlyName(
                for: "local/streaming/fluidaudio/parakeet-realtime-eou-120m"
            ),
            "Parakeet Realtime EOU 120M"
        )
        XCTAssertEqual(
            ModelCatalog.friendlyName(for: "local/post-processing/qwen3-0.6b-q4"),
            "Qwen3 0.6B Q4"
        )
        XCTAssertEqual(
            ModelCatalog.friendlyName(
                for: "local/post-processing/huggingface/unsloth/qwen3-0.6b-gguf/"
                    + "qwen3-0.6b-q4-k-m.gguf"
            ),
            "Qwen3 0.6B Q4_K_M"
        )
        XCTAssertEqual(
            ModelCatalog.friendlyName(
                for: "local/whisperkit/huggingface/argmaxinc/whisperkit-coreml/openai-whisper-large-v3-turbo-954mb"
            ),
            "Openai Whisper Large V3 Turbo 954 MB"
        )
    }

    func testFriendlyName_parakeetV3SherpaSource_returnsDisplayName() {
        XCTAssertEqual(
            ModelCatalog.friendlyName(for: ParakeetLocalModels.tdtV3Int8SourceID),
            ParakeetLocalModels.tdtV3DisplayName
        )
    }

    func testParakeetV3Catalogue_pinsArtifactURLAndChecksum() throws {
        let url = try XCTUnwrap(ParakeetLocalModels.tdtV3Int8ArchiveURL)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasPrefix("/k2-fsa/sherpa-onnx/releases/download/asr-models/"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".tar.bz2"))
        XCTAssertTrue(url.lastPathComponent.contains(ParakeetLocalModels.tdtV3Int8ModelName))

        XCTAssertEqual(ParakeetLocalModels.tdtV3Int8ArchiveSHA256.count, 64)
        XCTAssertTrue(ParakeetLocalModels.tdtV3Int8ArchiveSHA256.allSatisfy(\.isHexDigit))
    }

    func testParakeetV3Catalogue_describesLanguagesRAMAndLicence() {
        let codes = ParakeetLocalModels.tdtV3LanguageCodes
        XCTAssertEqual(codes.count, 25, "Parakeet v3 auto-detects among 25 European languages")
        XCTAssertEqual(Set(codes).count, codes.count, "Language codes should be unique")
        XCTAssertTrue(codes.allSatisfy { $0.count == 2 && $0 == $0.lowercased() })
        for expected in ["en", "de", "fr", "es", "uk"] {
            XCTAssertTrue(codes.contains(expected), "Missing \(expected)")
        }
        XCTAssertTrue(ParakeetLocalModels.tdtV3SupportsLanguageAutoDetection)

        XCTAssertEqual(ParakeetLocalModels.tdtV3License, "CC-BY-4.0")
        XCTAssertGreaterThan(ParakeetLocalModels.tdtV3Int8DownloadSizeMB, 0)
        XCTAssertGreaterThan(
            ParakeetLocalModels.tdtV3Int8InstalledSizeMB,
            ParakeetLocalModels.tdtV3Int8DownloadSizeMB
        )
        XCTAssertGreaterThan(
            ParakeetLocalModels.tdtV3ApproximateRAMMB,
            ParakeetLocalModels.tdtV3Int8InstalledSizeMB,
            "RAM guidance should exceed the on-disk model size"
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
        }
    }

    func testWhisperKitLocalTranscription_advertisesLiveStreamingSupport() {
        let whisperKitModels = ModelCatalog.localTranscription.filter { $0.engine == .whisperKit }

        XCTAssertFalse(whisperKitModels.isEmpty)
        for model in whisperKitModels {
            XCTAssertTrue(model.supportsLiveStreaming, "\(model.id) should advertise its in-process live path")
        }
    }

    func testModelRouting_distinguishesAppleSpeechFromDownloadedLocal() {
        XCTAssertEqual(ModelRouting.family(for: "apple/local/SFSpeechRecognizer"), .appleSpeech)
        XCTAssertEqual(ModelRouting.family(for: "apple/local/SpeechTranscriber"), .appleSpeech)
        XCTAssertEqual(ModelRouting.family(for: "local/whisperkit/tiny"), .downloadedLocal(engine: .whisperKit))
        XCTAssertEqual(
            ModelRouting.family(for: "local/transcribe.cpp/whisper-large-v3-turbo"),
            .downloadedLocal(engine: .transcribeCpp)
        )
    }

    func testLocalTranscriptionEngine_preservesUnknownBoundaryValues() throws {
        let engine = LocalTranscriptionEngine(identifier: "Future-Runtime")

        XCTAssertEqual(engine, .unknown("future-runtime"))
        XCTAssertEqual(engine.identifier, "future-runtime")
        XCTAssertEqual(
            try JSONDecoder().decode(
                LocalTranscriptionEngine.self,
                from: Data(#""transcribe-cpp""#.utf8)
            ),
            .transcribeCpp
        )
        XCTAssertEqual(String(data: try JSONEncoder().encode(engine), encoding: .utf8), #""future-runtime""#)
    }

    func testLiveTranscriptionPlacement_keepsAppleModelsOnlyOnDevice() {
        let onDeviceIDs = Set(ModelCatalog.onDeviceLiveTranscription.map(\.id))
        let remoteIDs = Set(ModelCatalog.remoteLiveTranscription.map(\.id))

        XCTAssertTrue(onDeviceIDs.contains(AppleLocalModels.preferredSpeechModelID))
        XCTAssertTrue(onDeviceIDs.contains("apple/local/Dictation"))
        XCTAssertTrue(onDeviceIDs.allSatisfy(ModelCatalog.isOnDeviceLiveTranscriptionModel))
        XCTAssertTrue(remoteIDs.allSatisfy { !ModelCatalog.isOnDeviceLiveTranscriptionModel($0) })
        XCTAssertTrue(onDeviceIDs.isDisjoint(with: remoteIDs))
        XCTAssertEqual(onDeviceIDs.union(remoteIDs), Set(ModelCatalog.liveTranscription.map(\.id)))
    }

    func testLiveTranscriptionPlacement_defaultsMatchTheirLocation() throws {
        XCTAssertTrue(ModelCatalog.isOnDeviceLiveTranscriptionModel(
            ModelCatalog.defaultOnDeviceLiveTranscriptionModel
        ))
        let remoteDefault = try XCTUnwrap(ModelCatalog.defaultRemoteLiveTranscriptionModel)
        XCTAssertFalse(ModelCatalog.isOnDeviceLiveTranscriptionModel(remoteDefault))
    }

    func testAppleSpeechCatalog_usesBestRuntimeAvailableModel() {
        let liveIDs = Set(ModelCatalog.liveTranscription.map(\.id))
        let batchIDs = Set(ModelCatalog.batchTranscription.map(\.id))
        XCTAssertTrue(liveIDs.contains(AppleLocalModels.preferredSpeechModelID))

        if AppleLocalModels.supportsSpeechTranscriber {
            XCTAssertTrue(batchIDs.contains(AppleLocalModels.speechTranscriberModelID))
            XCTAssertFalse(liveIDs.contains(AppleLocalModels.legacySpeechModelID))
            XCTAssertFalse(liveIDs.contains(AppleLocalModels.dictationTranscriberModelID))
        } else if AppleLocalModels.supportsDictationTranscriber {
            // OS 26 without Apple Intelligence: DictationTranscriber fills the gap.
            XCTAssertTrue(liveIDs.contains(AppleLocalModels.dictationTranscriberModelID))
            XCTAssertTrue(batchIDs.contains(AppleLocalModels.dictationTranscriberModelID))
            XCTAssertFalse(liveIDs.contains(AppleLocalModels.speechTranscriberModelID))
            XCTAssertFalse(liveIDs.contains(AppleLocalModels.legacySpeechModelID))
        } else {
            XCTAssertFalse(batchIDs.contains(AppleLocalModels.speechTranscriberModelID))
            XCTAssertFalse(batchIDs.contains(AppleLocalModels.dictationTranscriberModelID))
            XCTAssertFalse(liveIDs.contains(AppleLocalModels.speechTranscriberModelID))
            XCTAssertFalse(liveIDs.contains(AppleLocalModels.dictationTranscriberModelID))
            XCTAssertTrue(liveIDs.contains(AppleLocalModels.legacySpeechModelID))
        }
    }

    func testAppleSpeechModelSelection_preservesLegacyFallback() {
        XCTAssertEqual(
            AppleLocalModels.preferredSpeechModelID(speechTranscriberAvailable: true),
            AppleLocalModels.speechTranscriberModelID
        )
        XCTAssertEqual(
            AppleLocalModels.preferredSpeechModelID(speechTranscriberAvailable: false),
            AppleLocalModels.legacySpeechModelID
        )
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel(AppleLocalModels.legacySpeechModelID),
            AppleLocalModels.preferredSpeechModelID
        )
    }

    // Apple analyzer-engine selection and availability tests live in
    // AppleLocalModelsTests.swift.

    func testAppleFoundationModelCatalog_matchesRuntimeAvailability() {
        let isCatalogued = ModelCatalog.postProcessing.contains {
            $0.id == AppleLocalModels.foundationModelID
        }
        XCTAssertEqual(isCatalogued, AppleLocalModels.supportsFoundationModels)
        XCTAssertFalse(ModelCatalog.cloudPostProcessing.contains {
            $0.id == AppleLocalModels.foundationModelID
        })
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

    func testBatchTranscription_defaultAndRetiredMigrationStayInCatalogue() {
        let ids = Set(ModelCatalog.batchTranscription.map(\.id))

        XCTAssertTrue(ids.contains(ModelCatalog.defaultBatchTranscriptionModel))
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel("openrouter/whisper-large-v3"),
            ModelCatalog.defaultBatchTranscriptionModel
        )
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel(" custom/provider-model "),
            "custom/provider-model"
        )
    }

    func testPostProcessing_includesGPT56ModelsWithCurrentMetadata() {
        let expected: [String: ModelCatalog.Pricing] = [
            "openai/gpt-5.6-luna": .init(promptPerMTokens: 1.0, completionPerMTokens: 6.0),
            "openai/gpt-5.6-terra": .init(promptPerMTokens: 2.5, completionPerMTokens: 15.0),
            "openai/gpt-5.6-sol": .init(promptPerMTokens: 5.0, completionPerMTokens: 30.0)
        ]

        for (id, pricing) in expected {
            let option = ModelCatalog.postProcessing.first { $0.id == id }
            XCTAssertNotNil(option, "Missing \(id)")
            XCTAssertEqual(option?.pricing, pricing, "Incorrect pricing for \(id)")
            XCTAssertEqual(option?.contextLength, 1_050_000, "Incorrect context length for \(id)")
        }
    }

    func testPostProcessing_keepsLocalCleanupVisible() {
        let localCleanup = ModelCatalog.postProcessing.first {
            $0.id == "local/post-processing/rules"
        }

        XCTAssertNotNil(localCleanup)
        XCTAssertTrue(localCleanup?.tags.contains(.privacy) == true)
    }

    func testCloudPostProcessing_isExactNonLocalProjection() {
        XCTAssertEqual(
            ModelCatalog.cloudPostProcessing,
            ModelCatalog.postProcessing.filter {
                !$0.id.hasPrefix("local/post-processing/")
                    && $0.id != AppleLocalModels.foundationModelID
            }
        )
    }

    func testPostProcessingDefault_isAvailableCloudModel() {
        XCTAssertTrue(ModelCatalog.cloudPostProcessing.contains {
            $0.id == ModelCatalog.defaultPostProcessingModel
        })
    }

    func testPostProcessingNormalization_migratesRemovedModels() {
        for removed in [nil, "", "openai/gpt-4o-mini", "openrouter/gpt-4o", "unknown/model"] {
            XCTAssertEqual(
                ModelCatalog.normalizedPostProcessingModel(removed),
                ModelCatalog.defaultPostProcessingModel
            )
        }
        XCTAssertEqual(
            ModelCatalog.normalizedPostProcessingModel("openai/gpt-5.4-nano"),
            "openai/gpt-5.4-nano"
        )
        XCTAssertEqual(
            ModelCatalog.normalizedPostProcessingModel("local/post-processing/custom"),
            "local/post-processing/custom"
        )
    }
}
