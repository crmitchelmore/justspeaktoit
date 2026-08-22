import XCTest

@testable import SpeakCore

/// Routing metadata and save-time validation for dictation profiles (issue #690).
final class DictationProfileValidationTests: XCTestCase {
    private var catalogueLiveModel: String {
        ModelCatalog.liveTranscription.first { LiveTranscriptionRouting.route(for: $0.id) != nil }?.id
            ?? "deepgram/nova-3-streaming"
    }

    // MARK: - Routing

    func testDerivedRouting_matchesTheLegacyDerivation() {
        XCTAssertEqual(DictationProfile.derivedTranscriptionRouting(for: catalogueLiveModel), .remoteStreaming)
        XCTAssertEqual(DictationProfile.derivedTranscriptionRouting(for: "local/whisperkit/tiny"), .localBatch)
        XCTAssertEqual(DictationProfile.derivedTranscriptionRouting(for: "openai/whisper-1"), .remoteBatch)
        XCTAssertEqual(
            DictationProfile.derivedTranscriptionRouting(for: "deepgram/nova-4-custom-streaming"),
            .remoteBatch,
            "Without metadata an unlisted streaming id is still batch: that is the bug explicit routing fixes"
        )
    }

    func testResolvedOverride_prefersExplicitRouting() {
        let explicit = DictationProfile(
            name: "Custom",
            transcriptionModelID: "deepgram/nova-4-custom-streaming",
            transcriptionRouting: .remoteStreaming
        )
        XCTAssertEqual(explicit.resolvedTranscriptionOverride?.routing, .remoteStreaming)
        XCTAssertEqual(explicit.resolvedTranscriptionOverride?.modelID, "deepgram/nova-4-custom-streaming")

        let legacy = DictationProfile(name: "Legacy", transcriptionModelID: " openai/whisper-1 ")
        XCTAssertEqual(legacy.resolvedTranscriptionOverride?.routing, .remoteBatch)
        XCTAssertEqual(legacy.resolvedTranscriptionOverride?.modelID, "openai/whisper-1")

        XCTAssertNil(DictationProfile(name: "Default").resolvedTranscriptionOverride)
        XCTAssertNil(DictationProfile(name: "Blank", transcriptionModelID: "  ").resolvedTranscriptionOverride)
    }

    func testLocalRoutingAndLocalIdentifiers_mustAgree() {
        let localUnderLocal = DictationProfile(
            name: "Local", transcriptionModelID: "local/whisperkit/tiny", transcriptionRouting: .localBatch
        )
        XCTAssertEqual(DictationProfileValidator.issues(for: localUnderLocal), [])

        // A local identifier stored under remote batch would be sent to a cloud provider.
        let localUnderRemote = DictationProfile(
            name: "Mismatch", transcriptionModelID: "local/whisperkit/tiny", transcriptionRouting: .remoteBatch
        )
        XCTAssertEqual(
            DictationProfileValidator.issues(for: localUnderRemote),
            [.localModelUnderRemoteRouting(modelID: "local/whisperkit/tiny")]
        )

        // Local routing can only run a downloaded local model.
        let remoteUnderLocal = DictationProfile(
            name: "Mismatch", transcriptionModelID: "openai/whisper-1", transcriptionRouting: .localBatch
        )
        XCTAssertEqual(
            DictationProfileValidator.issues(for: remoteUnderLocal),
            [.unknownLocalModel(modelID: "openai/whisper-1")]
        )
        XCTAssertFalse(DictationProfileIssue.unknownLocalModel(modelID: "x").message.isEmpty)
        XCTAssertFalse(DictationProfileIssue.localModelUnderRemoteRouting(modelID: "x").message.isEmpty)
    }

    func testCodable_roundTripsRoutingAndDecodesLegacyProfilesWithoutIt() throws {
        let profile = DictationProfile(
            name: "Slack",
            matchers: [.bundleID("com.tinyspeck.slackmacgap")],
            transcriptionModelID: "deepgram/nova-4-custom-streaming",
            transcriptionRouting: .remoteStreaming
        )
        let decoded = try DictationProfile.decodeList(DictationProfile.encodeList([profile]))
        XCTAssertEqual(decoded, [profile])
        XCTAssertEqual(decoded.first?.transcriptionRouting, .remoteStreaming)

        let legacyJSON = """
        [{"id":"\(UUID().uuidString)","name":"Legacy","matchers":[],"transcriptionModelID":"openai/whisper-1"}]
        """
        let legacy = try DictationProfile.decodeList(Data(legacyJSON.utf8))
        XCTAssertNil(legacy.first?.transcriptionRouting)
        XCTAssertEqual(legacy.first?.resolvedTranscriptionOverride?.routing, .remoteBatch)
    }

    func testCodable_dropsUnknownRoutingInsteadOfFailing() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Future","matchers":[],"transcriptionModelID":"x/y",\
        "transcriptionRouting":"quantumStreaming"}]
        """
        let decoded = try DictationProfile.decodeList(Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded.first?.transcriptionRouting)
    }

    // MARK: - Validation

    func testValidator_acceptsCatalogueAndRoutableCustomStreamingModels() {
        let catalogue = DictationProfile(
            name: "Catalogue", transcriptionModelID: catalogueLiveModel, transcriptionRouting: .remoteStreaming
        )
        XCTAssertEqual(DictationProfileValidator.issues(for: catalogue), [])

        let custom = DictationProfile(
            name: "Custom",
            transcriptionModelID: "deepgram/nova-4-custom-streaming",
            transcriptionRouting: .remoteStreaming
        )
        XCTAssertEqual(DictationProfileValidator.issues(for: custom), [])
        XCTAssertTrue(DictationProfileValidator.isRoutableStreamingModel("deepgram/nova-4-custom-streaming"))
    }

    func testValidator_rejectsStreamingModelsWithoutALiveProvider() {
        let profile = DictationProfile(
            name: "Unknown", transcriptionModelID: "acme/fast-streaming", transcriptionRouting: .remoteStreaming
        )
        XCTAssertEqual(
            DictationProfileValidator.issues(for: profile),
            [.unknownStreamingProvider(modelID: "acme/fast-streaming")]
        )
        XCTAssertFalse(DictationProfileValidator.isRoutableStreamingModel("acme/fast-streaming"))
        XCTAssertFalse(DictationProfileValidator.isRoutableStreamingModel("no-provider"))
    }

    func testValidator_batchRoutingDoesNotRequireALiveProvider() {
        let profile = DictationProfile(
            name: "Batch", transcriptionModelID: "acme/fast", transcriptionRouting: .remoteBatch
        )
        XCTAssertEqual(DictationProfileValidator.issues(for: profile), [])
    }

    func testValidator_polishModelMustBeOneTheAppRuns() {
        XCTAssertTrue(DictationProfileValidator.isSupportedPolishModel(ModelCatalog.defaultPostProcessingModel))
        XCTAssertTrue(DictationProfileValidator.isSupportedPolishModel("local/post-processing/rules"))
        XCTAssertFalse(DictationProfileValidator.isSupportedPolishModel("unknown/model"))
        XCTAssertFalse(DictationProfileValidator.isSupportedPolishModel(""))

        let profile = DictationProfile(name: "Polish", polishEnabled: true, polishModelID: "unknown/model")
        XCTAssertEqual(
            DictationProfileValidator.issues(for: profile),
            [.unsupportedPolishModel(modelID: "unknown/model")]
        )
    }

    func testValidator_requiresAName() {
        XCTAssertEqual(DictationProfileValidator.issues(for: DictationProfile(name: "  ")), [.emptyName])
        XCTAssertFalse(DictationProfileIssue.emptyName.message.isEmpty)
    }
}
