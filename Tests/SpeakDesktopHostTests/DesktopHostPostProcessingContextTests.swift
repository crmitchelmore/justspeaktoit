import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostPostProcessingContextTests: XCTestCase {
    private var directory: URL!
    private var effects: LocalRulesEffects!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("post-context-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = LocalRulesEffects()
        controller = try DesktopHostController(directory: directory, effects: effects)
        guard case .apiKey(let identifier, _) = ModelCredentialResolver.requirement(
            for: ModelCatalog.defaultPostProcessingModel, purpose: .postProcessing
        ) else { throw DesktopPostProcessingError.unsupportedModel }
        FakeLog.shared.setKey("synthetic-key", name: identifier)
    }

    override func tearDown() async throws {
        await controller.close()
        FakeLog.shared.reset()
        try FileManager.default.removeItem(at: directory)
    }

    private func record() -> DesktopRecordingStore.Record {
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "synthetic.wav", modelIdentifier: ModelCatalog.defaultBatchTranscriptionModel
        )
        record.result = TranscriptionResult(
            text: "hello", segments: [], confidence: nil, duration: 1, modelIdentifier: record.modelIdentifier,
            cost: nil, rawPayload: nil, debugInfo: nil
        )
        record.lexiconDirectives = ["Stored directive"]
        record.lexiconContextTags = ["Stored tag"]
        return record
    }

    func testRequestOmissionUsesFrozenOptionsAndNeverErasesRecordContext() async {
        for directives in [true, false] {
            for tags in [true, false] {
                await controller.savePostProcessing(
                    enabled: true, modelIdentifier: ModelCatalog.defaultPostProcessingModel, prompt: "Keep.", key: "",
                    includeLexiconDirectives: directives, includeContextTags: tags
                )
                let snapshot = await controller.postProcessingOptions()
                await controller.savePostProcessing(
                    enabled: false, modelIdentifier: LocalPostProcessingModel.builtInRulesModelID, prompt: "", key: "",
                    includeLexiconDirectives: !directives, includeContextTags: !tags
                )
                let original = record()
                let result = await controller.postProcess(original, options: snapshot)
                XCTAssertNil(result.postProcessingFailure)
                XCTAssertEqual(effects.requests.last?.directives, directives ? original.lexiconDirectives : [])
                XCTAssertEqual(effects.requests.last?.tags, tags ? original.lexiconContextTags : [])
                XCTAssertEqual(result.lexiconDirectives, original.lexiconDirectives)
                XCTAssertEqual(result.lexiconContextTags, original.lexiconContextTags)
                let current = await controller.postProcessingOptions()
                XCTAssertEqual(current.mode, .disabled)
                XCTAssertEqual(current.includeLexiconDirectives, !directives)
                XCTAssertEqual(current.includeContextTags, !tags)
            }
        }
    }

    func testFalseImportRestartExportAndLocalExecutionKeepBothSwitchesWithoutCredentials() async throws {
        let rules = LocalPostProcessingModel.builtInRulesModelID
        await controller.savePostProcessing(enabled: true, modelIdentifier: rules, prompt: "", key: "")
        let file = directory.appendingPathComponent("context.json")
        let preferences = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.postProcessingIncludeLexiconDirectives.rawValue: AnyCodable(.bool(false)),
            ApplicationPreferenceKey.postProcessingIncludeContextTags.rawValue: AnyCodable(.bool(false))
        ])
        let probe = LocalRulesCredentialProbe()
        FakeLog.shared.installKeyReadHook { _ in probe.read() }
        FakeLog.shared.installKeyWriteHook { _, _ in probe.write() }
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences)).write(to: file)
        try await controller.importConfiguration(path: file.path)
        await controller.close()
        controller = try DesktopHostController(directory: directory, effects: effects)
        let restored = await controller.postProcessingOptions()
        XCTAssertEqual(restored.mode, .local)
        XCTAssertEqual(restored.modelIdentifier, rules)
        XCTAssertFalse(restored.includeLexiconDirectives)
        XCTAssertFalse(restored.includeContextTags)
        let original = record()
        let result = await controller.postProcess(original, options: restored)
        XCTAssertEqual(effects.requests.last?.directives, [])
        XCTAssertEqual(effects.requests.last?.tags, [])
        XCTAssertEqual(result.lexiconDirectives, original.lexiconDirectives)
        XCTAssertEqual(result.lexiconContextTags, original.lexiconContextTags)
        try await controller.exportConfiguration(path: file.path)
        let exported = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: file))
        for (key, value) in preferences.values { XCTAssertEqual(exported.preferences.values[key], value) }
        let stored = try await controller.configuration()
        let configuration = await controller.settings.configuration
        let authority = try XCTUnwrap(configuration)
        XCTAssertTrue(DesktopPostProcessingConfiguration.keys.isDisjoint(with: authority.values.keys))
        XCTAssertEqual(stored.values[DesktopPostProcessingConfiguration.streamingKey], AnyCodable(.bool(false)))
        XCTAssertFalse(restored.streamingEnabled)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(probe.writes, 0)
    }

    func testFlagsOnlyImportKeepsNondefaultScalarsInRuntimeViewRestartAndExport() async throws {
        let temperature = ApplicationPreferenceKey.postProcessingTemperature.rawValue
        let language = ApplicationPreferenceKey.postProcessingOutputLanguage.rawValue
        let initial = try DesktopConfiguration(values: [
            temperature: AnyCodable(.double(0.73)), language: AnyCodable(.string("French"))
        ])
        try await controller.saveConfiguration(initial.entries)
        let flags = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.postProcessingIncludeLexiconDirectives.rawValue: AnyCodable(.bool(false)),
            ApplicationPreferenceKey.postProcessingIncludeContextTags.rawValue: AnyCodable(.bool(false))
        ])
        let file = directory.appendingPathComponent("flags-only.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: flags)).write(to: file)
        try await controller.importConfiguration(path: file.path)
        for restart in [false, true] {
            if restart {
                await controller.close()
                controller = try DesktopHostController(directory: directory, effects: effects)
            }
            let options = await controller.postProcessingOptions()
            let view = try await controller.configuration()
            XCTAssertEqual(options.temperature, 0.73)
            XCTAssertEqual(options.outputLanguage, "French")
            XCTAssertFalse(options.includeLexiconDirectives)
            XCTAssertFalse(options.includeContextTags)
            XCTAssertEqual(view.number(temperature), options.temperature)
            XCTAssertEqual(view.text(language), options.outputLanguage)
            try await controller.exportConfiguration(path: file.path)
            let exported = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: file))
            XCTAssertEqual(exported.preferences.number(temperature), options.temperature)
            XCTAssertEqual(exported.preferences.text(language), options.outputLanguage)
            for (key, value) in flags.values { XCTAssertEqual(exported.preferences.values[key], value) }
        }
    }

    func testLocalRestartRecallsNondefaultRemoteWithoutActivatingOrReadingCredentials() async throws {
        let remote = try XCTUnwrap(DesktopPostProcessing.remoteModels.first {
            $0.id != ModelCatalog.defaultPostProcessingModel
        }?.id)
        let probe = try await prepareLocalRecall(remote)
        let local = await controller.postProcessingOptions()
        XCTAssertEqual(local.mode, .local)
        XCTAssertEqual(local.lastRemoteModelIdentifier, remote)
        XCTAssertEqual(local.temperature, 0.64)
        XCTAssertEqual(local.outputLanguage, "German")
        XCTAssertEqual(local.customPrompt, "Retain remote instructions.")
        XCTAssertFalse(local.includeLexiconDirectives)
        XCTAssertFalse(local.includeContextTags)
        await controller.close()
        controller = try DesktopHostController(directory: directory, effects: effects)
        let restarted = await controller.postProcessingOptions()
        XCTAssertEqual(restarted, local)
        let index = try XCTUnwrap(DesktopPostProcessing.remoteSelection(for: restarted))
        let recalled = try XCTUnwrap(DesktopPostProcessing.modelIdentifier(forSelection: index))
        XCTAssertEqual(recalled, remote)
        XCTAssertEqual(restarted.mode, .local, "Picker recall must not activate remote cleanup")
        let file = directory.appendingPathComponent("local-recall.json")
        try await controller.exportConfiguration(path: file.path)
        let exported = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: file))
        XCTAssertEqual(
            exported.preferences.values[ApplicationPreferenceKey.postProcessingModel.rawValue],
            AnyCodable(.string(LocalPostProcessingModel.builtInRulesModelID))
        )
        XCTAssertNil(exported.preferences.values["lastRemoteModelIdentifier"])
        await controller.savePostProcessing(
            enabled: true, modelIdentifier: recalled, prompt: restarted.customPrompt ?? "", key: ""
        )
        let applied = await controller.postProcessingOptions()
        XCTAssertEqual(applied.mode, .remote)
        XCTAssertEqual(applied.modelIdentifier, remote)
        XCTAssertEqual(applied.lastRemoteModelIdentifier, remote)
        XCTAssertEqual(applied.customPrompt, local.customPrompt)
        XCTAssertEqual(applied.temperature, local.temperature)
        XCTAssertEqual(applied.outputLanguage, local.outputLanguage)
        XCTAssertEqual(applied.includeLexiconDirectives, local.includeLexiconDirectives)
        XCTAssertEqual(applied.includeContextTags, local.includeContextTags)
        XCTAssertTrue(effects.requests.isEmpty)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(probe.writes, 0)
    }

    private func prepareLocalRecall(_ remote: String) async throws -> LocalRulesCredentialProbe {
        let initial = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.postProcessingTemperature.rawValue: AnyCodable(.double(0.64)),
            ApplicationPreferenceKey.postProcessingOutputLanguage.rawValue: AnyCodable(.string("German"))
        ])
        try await controller.saveConfiguration(initial.entries)
        let probe = LocalRulesCredentialProbe()
        FakeLog.shared.installKeyReadHook { _ in probe.read() }
        FakeLog.shared.installKeyWriteHook { _, _ in probe.write() }
        await controller.savePostProcessing(
            enabled: true, modelIdentifier: remote, prompt: "Retain remote instructions.", key: "",
            includeLexiconDirectives: false, includeContextTags: false
        )
        await controller.savePostProcessing(
            enabled: true, modelIdentifier: LocalPostProcessingModel.builtInRulesModelID, prompt: "", key: "ignored"
        )
        return probe
    }
}
