import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopLocalLLMProfileTests: XCTestCase {
    func testDownloadedProfileKeepsBothExplicitContextSwitchesAndPrompt() throws {
        let model = try LocalLLMFixture.model()
        let defaults = DesktopPostProcessing.Options(mode: .localLLM, modelIdentifier: model.id)
        var profile = DictationProfile(name: "Local context")
        profile.polishPrompt = "Keep the requested format."
        profile.polishIncludeLexiconDirectives = false
        profile.polishIncludeContextTags = false
        let options = resolve(profile, defaults: defaults, model: model).postProcessing
        XCTAssertEqual(options.mode, .localLLM)
        XCTAssertEqual(options.customPrompt, "Keep the requested format.")
        XCTAssertFalse(options.includeLexiconDirectives)
        XCTAssertFalse(options.includeContextTags)
        let context = options.lexiconContext(directives: ["No leak"], tags: ["No leak"])
        XCTAssertTrue(context.directives.isEmpty)
        XCTAssertTrue(context.tags.isEmpty)
    }

    func testProfileEnableWithInheritedLocalModelDoesNotSwitchToRemote() throws {
        let model = try LocalLLMFixture.model()
        let defaults = DesktopPostProcessing.Options(
            mode: .disabled, modelIdentifier: model.id, customPrompt: "Default prompt", temperature: 0.2
        )
        let result = resolve(
            .init(name: "Local", polishEnabled: true, polishPrompt: "One stop per word."),
            defaults: defaults, model: model
        )
        XCTAssertEqual(result.postProcessing.mode, .localLLM)
        XCTAssertEqual(result.postProcessing.modelIdentifier, model.id)
        XCTAssertEqual(result.postProcessing.customPrompt, "One stop per word.")
        XCTAssertEqual(result.postProcessing.temperature, 0.2)
        XCTAssertEqual(defaults.mode, .disabled)
    }

    func testProfileCanExplicitlyChooseDownloadedLocalModelButCannotFallbackFromMissingOverride() throws {
        let model = try LocalLLMFixture.model()
        let defaults = DesktopPostProcessing.Options(mode: .remote)
        let chosen = resolve(
            .init(name: "Local override", polishEnabled: true, polishModelID: model.id),
            defaults: defaults, model: model
        )
        XCTAssertEqual(chosen.postProcessing.mode, .localLLM)
        XCTAssertEqual(chosen.postProcessing.modelIdentifier, model.id)
        let missing = resolve(
            .init(name: "Missing", polishModelID: "local/post-processing/not-imported"),
            defaults: chosen.postProcessing, model: model
        )
        XCTAssertEqual(missing.postProcessing.mode, .disabled)
        XCTAssertNotNil(missing.skippedPolishReason)
        XCTAssertTrue(missing.limitations.contains(.polishModelUnavailable(
            modelID: "local/post-processing/not-imported"
        )))
    }

    private func resolve(
        _ profile: DictationProfile, defaults: DesktopPostProcessing.Options, model: HuggingFaceGGUFModel
    ) -> DesktopProfileSession {
        DesktopProfileSessionResolver.resolve(
            profile: profile, defaultModel: ModelCatalog.defaultBatchTranscriptionModel,
            defaultPostProcessing: defaults, capabilities: .init(
                batchModels: DesktopTranscription.batchModels, liveModels: [],
                polishModels: DesktopPostProcessing.remoteModels + [model.model.option]
            )
        )
    }
}
