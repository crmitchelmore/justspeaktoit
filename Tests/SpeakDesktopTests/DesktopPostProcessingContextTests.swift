import Foundation
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
import XCTest

final class DesktopPostProcessingContextTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testOriginalFiveLabelInitializerReferencePreservesArgumentsAndCanonicalDefaults() throws {
        let initialize: (
            DesktopPostProcessing.Mode, String, String?, String?, Double
        ) -> DesktopPostProcessing.Options = DesktopPostProcessing.Options.init(
            mode:modelIdentifier:customPrompt:outputLanguage:temperature:
        )
        let model = try XCTUnwrap(DesktopPostProcessing.remoteModels.last?.id)
        let options = initialize(.remote, model, "Keep case.", "French", 0.73)
        XCTAssertEqual(options, DesktopPostProcessing.Options(
            mode: .remote, modelIdentifier: model, customPrompt: "Keep case.",
            outputLanguage: "French", temperature: 0.73,
            includeLexiconDirectives: SpeechDefaults.postProcessingIncludeLexiconDirectives,
            includeContextTags: SpeechDefaults.postProcessingIncludeContextTags
        ))
        XCTAssertEqual(options.lastRemoteModelIdentifier, model)
        XCTAssertEqual(DesktopPostProcessing.Options(), initialize(
            .disabled, ModelCatalog.defaultPostProcessingModel, nil, nil, SpeechDefaults.temperature
        ))
    }

    func testLegacyOptionsUseMacTrueDefaultsAndExplicitInvalidBooleansAreRefused() throws {
        let old = """
        {"mode":"remote","modelIdentifier":"\(ModelCatalog.defaultPostProcessingModel)","temperature":0.2}
        """
        let defaults = try JSONDecoder().decode(DesktopPostProcessing.Options.self, from: Data(old.utf8))
        XCTAssertTrue(defaults.includeLexiconDirectives)
        XCTAssertTrue(defaults.includeContextTags)
        for field in ["includeLexiconDirectives", "includeContextTags"] {
            for invalid in [#""false""#, "0", "null"] {
                let modified = String(old.dropLast()) + ",\"\(field)\":\(invalid)}"
                XCTAssertThrowsError(try JSONDecoder().decode(
                    DesktopPostProcessing.Options.self, from: Data(modified.utf8)
                ))
            }
        }
    }

    func testEverySwitchCombinationFiltersTheActualRemotePrompt() async throws {
        for directives in [true, false] {
            for tags in [true, false] {
                let options = DesktopPostProcessing.Options(
                    mode: .remote, includeLexiconDirectives: directives, includeContextTags: tags
                )
                StubURLProtocol.handler = { request in
                    let body = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                    )
                    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
                    let system = try XCTUnwrap(messages.first?["content"])
                    XCTAssertEqual(system.contains("UNIQUE_DIRECTIVE"), directives)
                    XCTAssertEqual(system.contains("UNIQUE_CONTEXT_TAG"), tags)
                    return .ok(Data(#"{"choices":[{"message":{"content":"Clean"}}]}"#.utf8), url: request.url!)
                }
                _ = try await DesktopPostProcessing.process(
                    rawText: "hello", options: options, apiKey: "synthetic-key",
                    lexiconDirectives: ["UNIQUE_DIRECTIVE"], lexiconContextTags: ["UNIQUE_CONTEXT_TAG"],
                    session: StubURLProtocol.makeSession()
                )
            }
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 4)
    }

    func testProfileSwitchesOverrideAppDefaultsAndRemainFrozenWithoutChangingStoredContext() {
        var defaults = DesktopPostProcessing.Options(
            mode: .remote, includeLexiconDirectives: true, includeContextTags: false
        )
        let session = DesktopProfileSessionResolver.resolve(
            profile: DictationProfile(
                name: "Context", polishIncludeLexiconDirectives: false, polishIncludeContextTags: true
            ),
            defaultModel: ModelCatalog.defaultBatchTranscriptionModel, defaultPostProcessing: defaults,
            capabilities: .shared
        )
        defaults.includeLexiconDirectives = true
        defaults.includeContextTags = false
        XCTAssertFalse(session.postProcessing.includeLexiconDirectives)
        XCTAssertTrue(session.postProcessing.includeContextTags)
        XCTAssertTrue(session.limitations.isEmpty)
        let inherited = DesktopProfileSessionResolver.resolve(
            profile: DictationProfile(name: "Inherit"), defaultModel: ModelCatalog.defaultBatchTranscriptionModel,
            defaultPostProcessing: defaults, capabilities: .shared
        )
        XCTAssertEqual(inherited.postProcessing, defaults)
        var local = defaults
        local.mode = .local
        local.modelIdentifier = LocalPostProcessingModel.builtInRulesModelID
        let context = local.lexiconContext(directives: ["Keep"], tags: ["Keep"])
        XCTAssertTrue(context.directives.isEmpty)
        XCTAssertTrue(context.tags.isEmpty)
        XCTAssertTrue(DesktopPostProcessing.localRulesNotice.contains("lexicon context"))
    }

    func testNativeApplyWireRetainsPromptDelimitersAndRejectsMalformedSwitches() throws {
        let prompt = "Keep 100%.\t\n\u{1F}caf\u{e9}"
        let encoded = DesktopVocabularyWire.encode([prompt, "synthetic-key", "0", "1"])
        let fields = try DesktopPostProcessing.nativeFields(encoded)
        XCTAssertEqual(fields.prompt, prompt)
        XCTAssertEqual(fields.key, "synthetic-key")
        XCTAssertFalse(fields.includeLexiconDirectives)
        XCTAssertTrue(fields.includeContextTags)
        for invalid in ["prompt\tkey\tfalse\t1", "prompt\tkey\t0\t2", "prompt\tkey", "%ZZ\t\t1\t1"] {
            XCTAssertThrowsError(try DesktopPostProcessing.nativeFields(invalid))
        }
    }

    func testDormantRemoteRecallDecodesLegacyOptionsAndNeverSubstitutesUnavailableModels() throws {
        let remote = try XCTUnwrap(DesktopPostProcessing.remoteModels.last?.id)
        let old = """
        {"mode":"remote","modelIdentifier":"\(remote)","temperature":0.2}
        """
        let legacy = try JSONDecoder().decode(DesktopPostProcessing.Options.self, from: Data(old.utf8))
        XCTAssertEqual(legacy.lastRemoteModelIdentifier, remote)
        XCTAssertEqual(
            DesktopPostProcessing.remoteSelection(for: legacy),
            DesktopPostProcessing.models.firstIndex { $0.id == remote }
        )
        for unavailable in ["openrouter/unavailable", LocalPostProcessingModel.builtInRulesModelID] {
            let local = DesktopPostProcessing.Options(
                mode: .local, modelIdentifier: LocalPostProcessingModel.builtInRulesModelID,
                includeLexiconDirectives: SpeechDefaults.postProcessingIncludeLexiconDirectives,
                includeContextTags: SpeechDefaults.postProcessingIncludeContextTags,
                lastRemoteModelIdentifier: unavailable
            )
            let restored = try JSONDecoder().decode(
                DesktopPostProcessing.Options.self, from: JSONEncoder().encode(local)
            )
            XCTAssertEqual(restored.lastRemoteModelIdentifier, unavailable)
            XCTAssertNil(DesktopPostProcessing.remoteSelection(for: restored))
            XCTAssertEqual(DesktopPostProcessing.migrated(restored), restored)
            let exported = try DesktopPostProcessingConfiguration.exportOptions(
                restored, over: DesktopConfiguration()
            )
            XCTAssertEqual(
                exported.values[ApplicationPreferenceKey.postProcessingModel.rawValue],
                AnyCodable(.string(LocalPostProcessingModel.builtInRulesModelID))
            )
            XCTAssertNil(exported.values["lastRemoteModelIdentifier"])
        }
    }
}
