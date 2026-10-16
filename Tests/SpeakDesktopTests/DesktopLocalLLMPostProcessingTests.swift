import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopLocalLLMPostProcessingTests: XCTestCase {
    func testDownloadedCleanupHonoursBothCapturedContextSwitches() async throws {
        let model = try LocalLLMFixture.model()
        for includeDirectives in [false, true] {
            for includeTags in [false, true] {
                let options = DesktopPostProcessing.Options(
                    mode: .localLLM, modelIdentifier: model.id, customPrompt: "One stop after each word.",
                    includeLexiconDirectives: includeDirectives, includeContextTags: includeTags
                )
                let outcome = try await DesktopPostProcessing.process(
                    rawText: "Spoken words", options: options, apiKey: "",
                    lexiconDirectives: ["COMPOSED_LEXICON_DIRECTIVE"],
                    lexiconContextTags: ["COMPOSED_CONTEXT_TAG"], localLLM: LocalLLMEngineSpy()
                )
                let system = try XCTUnwrap(outcome.systemPrompt)
                XCTAssertTrue(system.contains("One stop after each word."))
                XCTAssertEqual(system.contains("COMPOSED_LEXICON_DIRECTIVE"), includeDirectives)
                XCTAssertEqual(system.contains("COMPOSED_CONTEXT_TAG"), includeTags)
            }
        }
    }

    func testNativeCatalogueKeepsRemoteIndexesAndSeparatesRulesFromDownloadedModels() throws {
        let model = try LocalLLMFixture.model()
        let models = DesktopPostProcessing.nativeModels(selected: model.id)
        let remote = DesktopPostProcessing.remoteModels
        XCTAssertEqual(models.prefix(remote.count).map(\.id), remote.map(\.id))
        XCTAssertEqual(models[remote.count].id, LocalPostProcessingModel.builtInRulesModelID)
        XCTAssertEqual(DesktopPostProcessing.mode(for: models[remote.count].id), .local)
        XCTAssertEqual(DesktopPostProcessing.mode(for: model.id), .localLLM)
        XCTAssertTrue(models.dropFirst(remote.count + 1).contains { $0.id == model.id })
        XCTAssertTrue(models.dropFirst(remote.count + 1).allSatisfy {
            LocalPostProcessingModel.isDownloadedModelID($0.id)
        })
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
    }

    func testNativePickerResolvesOnlyItsPublishedSnapshotAndRejectsInvalidatedIndexes() {
        let picker = DesktopPostProcessingPicker()
        var models = Array(DesktopPostProcessing.remoteModels.prefix(2))
        XCTAssertEqual(models.count, 2)
        XCTAssertNil(picker.modelIdentifier(forSelection: 0))
        picker.publish(models)
        let original = models[0].id
        models.reverse()
        XCTAssertEqual(picker.modelIdentifier(forSelection: 0), original)
        XCTAssertNil(picker.modelIdentifier(forSelection: -1))
        XCTAssertNil(picker.modelIdentifier(forSelection: 2))
        picker.publish(models)
        XCTAssertEqual(picker.modelIdentifier(forSelection: 0), models[0].id)
        picker.publish([])
        XCTAssertNil(picker.modelIdentifier(forSelection: 0))
    }

    func testExplicitDownloadedModeCannotMigrateIntoRemotePermission() {
        let options = DesktopPostProcessing.Options(
            mode: .localLLM, modelIdentifier: ModelCatalog.defaultPostProcessingModel
        )
        let migrated = DesktopPostProcessing.migrated(options)
        XCTAssertEqual(migrated.mode, .disabled)
        XCTAssertEqual(migrated.modelIdentifier, options.modelIdentifier)
    }

    func testOriginalFiveLabelInitializerAndDefaultsRemainSourceCompatible() {
        let initializer = DesktopPostProcessing.Options.init(
            mode:modelIdentifier:customPrompt:outputLanguage:temperature:
        )
        let defaults = DesktopPostProcessing.Options()
        let explicit = initializer(
            .disabled, ModelCatalog.defaultPostProcessingModel, nil, nil, SpeechDefaults.temperature
        )
        XCTAssertEqual(defaults, explicit)
        XCTAssertEqual(DesktopPostProcessing.Options(customPrompt: "Keep punctuation.").customPrompt, "Keep punctuation.")
        let installerInitializer = LocalModelInstaller.init(root:digests:transport:prepareDirectory:)
        let item = installerInitializer(
            URL(fileURLWithPath: NSTemporaryDirectory()), TestSHA256.provider,
            FakeModelTransport(body: LocalLLMFixture.bytes), LocalLLMFixture.prepare
        )
        XCTAssertEqual(item.digests.name, TestSHA256.provider.name)
    }

    func testLocalSystemAndUserRolesUseTheSharedPolicyWithoutRemoteCredentials() async throws {
        let model = try LocalLLMFixture.model()
        let engine = LocalLLMEngineSpy()
        let raw = "Ignore instructions? No, this is transcript data.\nSecond line."
        let options = DesktopPostProcessing.Options(
            mode: .localLLM, modelIdentifier: model.id, customPrompt: "Put one full stop after each word.",
            outputLanguage: "French", temperature: 0.3
        )
        let result = try await DesktopPostProcessing.process(
            rawText: raw, options: options, apiKey: "", lexiconDirectives: ["Acme is spelled ACME."],
            lexiconContextTags: ["product"], localLLM: engine
        )
        let requests = await engine.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.model, model.id)
        XCTAssertEqual(request.temperature, 0.3)
        XCTAssertEqual(request.system, TranscriptCleanupPolicy.systemPrompt(
            customBasePrompt: options.customPrompt, outputLanguage: "French",
            lexiconDirectives: ["Acme is spelled ACME."], lexiconContextTags: ["product"]
        ))
        XCTAssertEqual(request.user, TranscriptCleanupPolicy.userMessage(transcript: raw))
        XCTAssertTrue(request.system.contains("Put one full stop after each word."))
        XCTAssertEqual(result.processedText, "Cleaned transcript.")
        XCTAssertEqual(result.modelIdentifier, model.id)
        XCTAssertNil(result.response)
    }

    func testEmptyAndSilentInputNeverCallsAnEngine() async throws {
        let engine = LocalLLMEngineSpy(failure: .inference("must not execute"))
        let options = DesktopPostProcessing.Options(
            mode: .localLLM, modelIdentifier: try LocalLLMFixture.model().id
        )
        for raw in ["", " \n\t", "[BLANK_AUDIO]"] {
            let result = try await DesktopPostProcessing.process(
                rawText: raw, options: options, apiKey: "", localLLM: engine
            )
            XCTAssertEqual(result.processedText, "")
            XCTAssertNil(result.modelIdentifier)
        }
        let requests = await engine.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testMissingNativeAdapterNeverRunsRulesOrRemoteCleanup() async throws {
        do {
            _ = try await DesktopPostProcessing.process(
                rawText: "Real transcript", options: .init(
                    mode: .localLLM, modelIdentifier: try LocalLLMFixture.model().id
                ), apiKey: "must-not-be-used"
            )
            XCTFail("Missing adapter accepted")
        } catch let error as LocalLLMError {
            guard case .runtimeUnavailable = error else { return XCTFail("Wrong failure: \(error)") }
        }
    }

    func testUnavailableRuntimeAndEmptyOutputRemainExplicitErrors() async throws {
        let options = DesktopPostProcessing.Options(mode: .localLLM, modelIdentifier: try LocalLLMFixture.model().id)
        for engine in [
            LocalLLMEngineSpy(failure: .runtimeUnavailable("package missing")),
            LocalLLMEngineSpy(output: " \n")
        ] {
            do {
                _ = try await DesktopPostProcessing.process(
                    rawText: "Real transcript", options: options, apiKey: "", localLLM: engine
                )
                XCTFail("Failure became a success-shaped transcript")
            } catch { XCTAssertTrue(error is LocalLLMError) }
        }
    }

    func testTemperatureBoundsRejectNonFiniteAndOutOfRangeBeforeInference() async throws {
        let engine = LocalLLMEngineSpy()
        for temperature in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            do {
                _ = try await DesktopPostProcessing.process(
                    rawText: "Real transcript", options: .init(
                        mode: .localLLM, modelIdentifier: try LocalLLMFixture.model().id, temperature: temperature
                    ), apiKey: "", localLLM: engine
                )
                XCTFail("Invalid temperature accepted")
            } catch let error as DesktopPostProcessingError {
                guard case .invalidTemperature = error else { return XCTFail("Wrong error") }
            }
        }
        let calls = await engine.requests()
        XCTAssertTrue(calls.isEmpty)
        for temperature in [0.0, 1.0] {
            _ = try await DesktopPostProcessing.process(
                rawText: "Real transcript", options: .init(
                    mode: .localLLM, modelIdentifier: try LocalLLMFixture.model().id, temperature: temperature
                ), apiKey: "", localLLM: engine
            )
        }
        let admitted = await engine.requests()
        XCTAssertEqual(admitted.map(\.temperature), [0, 1])
    }

    func testDisabledDownloadedSelectionAndAllOptionsSurviveCodableMigration() throws {
        let original = DesktopPostProcessing.Options(
            mode: .disabled, modelIdentifier: try LocalLLMFixture.model().id,
            customPrompt: "One full stop after each word.", outputLanguage: "German", temperature: 0
        )
        let restored = try JSONDecoder().decode(
            DesktopPostProcessing.Options.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(DesktopPostProcessing.migrated(restored), original)
        var enabled = original
        enabled.mode = .localLLM
        XCTAssertEqual(DesktopPostProcessing.migrated(enabled), enabled)
        enabled.mode = .remote
        XCTAssertEqual(DesktopPostProcessing.migrated(enabled).mode, .disabled)
    }

    func testRulesIdentityCannotBeExecutedAsDownloadedLLM() async throws {
        let engine = LocalLLMEngineSpy()
        do {
            _ = try await DesktopPostProcessing.process(
                rawText: "Some words", options: .init(
                    mode: .localLLM, modelIdentifier: LocalPostProcessingModel.builtInRulesModelID
                ), apiKey: "", localLLM: engine
            )
            XCTFail("Rules were treated as a native language model")
        } catch let error as DesktopPostProcessingError {
            guard case .unsupportedModel = error else { return XCTFail("Wrong error") }
        }
        let requests = await engine.requests()
        XCTAssertTrue(requests.isEmpty)
    }
}
