import Foundation
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
import XCTest

final class DesktopLocalRulesTests: XCTestCase {
    private let rules = LocalPostProcessingModel.builtInRulesModelID

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testCanonicalProjectionAndCallbackIndexesNeverShiftRemoteChoices() throws {
        XCTAssertEqual(DesktopPostProcessing.localModels,
                       ModelCatalog.postProcessing.filter { $0.id == rules })
        for (index, model) in DesktopPostProcessing.remoteModels.enumerated() {
            XCTAssertEqual(DesktopPostProcessing.modelIdentifier(forSelection: index), model.id)
            XCTAssertEqual(DesktopPostProcessing.mode(for: model.id), .remote)
        }
        let local = try XCTUnwrap(DesktopPostProcessing.models.firstIndex { $0.id == rules })
        XCTAssertEqual(DesktopPostProcessing.modelIdentifier(forSelection: local), rules)
        XCTAssertEqual(DesktopPostProcessing.selection(for: .init(mode: .local, modelIdentifier: rules)), local)
        XCTAssertEqual(DesktopPostProcessing.mode(for: rules), .local)
        XCTAssertNil(DesktopPostProcessing.modelIdentifier(forSelection: -1))
        XCTAssertNil(DesktopPostProcessing.modelIdentifier(forSelection: DesktopPostProcessing.models.count))
        XCTAssertNil(DesktopPostProcessing.selection(for: .init(modelIdentifier: "local/unavailable")))
        XCTAssertTrue(DesktopPostProcessing.localRulesNotice.contains("ignore custom instructions"))
        XCTAssertTrue(
            DesktopPostProcessing.localRulesNotice.contains("remote instructions and context switches are kept")
        )
        XCTAssertTrue(DesktopPostProcessing.localRulesNotice.contains("No API key"))
    }

    func testLocalExecutionMatchesMacPolicyAndIgnoresRemoteInputsWithoutRequests() async throws {
        let options = DesktopPostProcessing.Options(
            mode: .local, modelIdentifier: rules, customPrompt: "Put a full stop after every word.",
            outputLanguage: "French", temperature: .nan
        )
        for text in ["  hello  world ,this is a test!next  ", "[BLANK_AUDIO] hello [blank_audio]", "caf\u{e9} !"] {
            let outcome = try await DesktopPostProcessing.process(
                rawText: text, options: options, apiKey: "", lexiconDirectives: ["Ignore"],
                lexiconContextTags: ["Ignore"], session: StubURLProtocol.makeSession()
            )
            XCTAssertEqual(outcome.original, text)
            XCTAssertEqual(outcome.processedText, TranscriptPostProcessingPolicy.processLocally(text))
            XCTAssertEqual(outcome.modelIdentifier, rules)
            XCTAssertNil(outcome.systemPrompt)
            XCTAssertNil(outcome.userPrompt)
            XCTAssertNil(outcome.response)
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testLocalCancellationNeverInvokesNetwork() async {
        let rules = rules
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DesktopPostProcessing.process(
                rawText: "hello", options: .init(mode: .local, modelIdentifier: rules), apiKey: "",
                session: StubURLProtocol.makeSession()
            )
        }
        do { _ = try await task.value; XCTFail("Cancelled local cleanup succeeded") } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testUnsupportedLocalAndMismatchedLocationsNeverFallBackRemotely() async {
        let choices: [(DesktopPostProcessing.Mode, String)] = [
            (.local, "local/post-processing/huggingface/owner/model"),
            (.local, AppleLocalModels.foundationModelID), (.local, ModelCatalog.defaultPostProcessingModel),
            (.remote, rules)
        ]
        for (mode, model) in choices {
            do {
                _ = try await DesktopPostProcessing.process(
                    rawText: "hello", options: .init(mode: mode, modelIdentifier: model),
                    apiKey: "must-not-be-used", session: StubURLProtocol.makeSession()
                )
                XCTFail("Unsupported location/model succeeded")
            } catch DesktopPostProcessingError.unsupportedModel {
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testRestartMigrationPreservesLocalDisabledPromptsAndUnsupportedIdentifiers() throws {
        for mode in [DesktopPostProcessing.Mode.local, .disabled] {
            let options = DesktopPostProcessing.Options(
                mode: mode, modelIdentifier: rules, customPrompt: "Keep remote prompt.",
                outputLanguage: "fr", temperature: 0.4
            )
            let restored = try JSONDecoder().decode(
                DesktopPostProcessing.Options.self, from: JSONEncoder().encode(options)
            )
            XCTAssertEqual(DesktopPostProcessing.migrated(restored), options)
        }
        for identifier in ["local/post-processing/downloaded", "LOCAL/post-processing/unknown",
                           AppleLocalModels.foundationModelID] {
            let original = DesktopPostProcessing.Options(
                mode: .remote, modelIdentifier: identifier, customPrompt: "Keep."
            )
            let migrated = DesktopPostProcessing.migrated(original)
            XCTAssertEqual(migrated.mode, .disabled)
            XCTAssertEqual(migrated.modelIdentifier, identifier)
            XCTAssertEqual(migrated.customPrompt, "Keep.")
            XCTAssertEqual(DesktopPostProcessing.migrated(migrated), migrated)
        }
    }

    func testProfilesSelectLocalRulesWithoutChangingDefaultsOrLosingCustomInstructions() throws {
        let defaults = DesktopPostProcessing.Options(customPrompt: "App remote prompt.")
        let profile = DictationProfile(
            name: "Offline", polishEnabled: true, polishModelID: rules, polishPrompt: "Profile prompt."
        )
        let session = DesktopProfileSessionResolver.resolve(
            profile: profile, defaultModel: ModelCatalog.defaultBatchTranscriptionModel,
            defaultPostProcessing: defaults, capabilities: .shared
        )
        XCTAssertEqual(session.postProcessing.mode, .local)
        XCTAssertEqual(session.postProcessing.modelIdentifier, rules)
        XCTAssertEqual(session.postProcessing.customPrompt, defaults.customPrompt)
        XCTAssertTrue(session.limitations.isEmpty)
        XCTAssertNil(session.skippedPolishReason)
        XCTAssertEqual(defaults.mode, .disabled)
        let catalogue = DesktopProfileEditing.Catalogue(capabilities: .shared)
        let draft = DesktopProfileEditing.draft(for: profile, catalogue: catalogue)
        let local = try XCTUnwrap(catalogue.polishModels.firstIndex { $0.id == rules })
        XCTAssertEqual(draft.polishModel, .index(local))
        XCTAssertTrue(draft.notes.contains(DesktopPostProcessing.localRulesNotice))
        XCTAssertEqual(DesktopProfileEditing.profile(from: draft, original: profile, catalogue: catalogue), profile)
    }
}
