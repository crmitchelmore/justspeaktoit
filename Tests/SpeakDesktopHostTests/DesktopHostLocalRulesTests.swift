import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostLocalRulesTests: XCTestCase {
    private var directory: URL!
    private var effects: LocalRulesEffects!
    private var controller: DesktopHostController<FakePlatform>!
    private let rules = LocalPostProcessingModel.builtInRulesModelID

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-rules-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = LocalRulesEffects()
        controller = try DesktopHostController(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        FakeLog.shared.reset()
        try FileManager.default.removeItem(at: directory)
    }

    private func record(_ text: String) -> DesktopRecordingStore.Record {
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "synthetic.wav", modelIdentifier: ModelCatalog.defaultBatchTranscriptionModel
        )
        record.result = TranscriptionResult(
            text: text, segments: [], confidence: nil, duration: 1, modelIdentifier: record.modelIdentifier,
            cost: nil, rawPayload: nil, debugInfo: nil
        )
        return record
    }

    private func observeCredentials() -> LocalRulesCredentialProbe {
        let probe = LocalRulesCredentialProbe()
        FakeLog.shared.installKeyReadHook { _ in probe.read() }
        FakeLog.shared.installKeyWriteHook { _, _ in probe.write() }
        return probe
    }

    func testLocalApplyIgnoresTypedKeyPreservesRemotePromptAndSurvivesRestart() async throws {
        let remote = try XCTUnwrap(DesktopPostProcessing.remoteModels.last?.id)
        await controller.savePostProcessing(
            enabled: true, modelIdentifier: remote, prompt: "Keep remote instructions.", key: ""
        )
        let probe = observeCredentials()
        await controller.savePostProcessing(enabled: true, modelIdentifier: rules, prompt: "", key: "must-not-save")
        let enabled = await controller.postProcessingOptions()
        XCTAssertEqual(enabled.mode, .local)
        XCTAssertEqual(enabled.modelIdentifier, rules)
        XCTAssertEqual(enabled.customPrompt, "Keep remote instructions.")
        await controller.close()
        controller = try DesktopHostController(directory: directory, effects: effects)
        let restarted = await controller.postProcessingOptions()
        XCTAssertEqual(restarted, enabled)
        await controller.savePostProcessing(enabled: false, modelIdentifier: rules, prompt: "", key: "must-not-save")
        await controller.close()
        controller = try DesktopHostController(directory: directory, effects: effects)
        let disabled = await controller.postProcessingOptions()
        XCTAssertEqual(disabled.mode, .disabled)
        XCTAssertEqual(disabled.modelIdentifier, rules)
        XCTAssertEqual(disabled.customPrompt, enabled.customPrompt)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(probe.writes, 0)
    }

    func testVoiceCommandsAndCorrectionsReachRealLocalRulesAndHistoryKeepsFriendlyIdentity() async throws {
        let probe = observeCredentials()
        var original = record("please copy pasta ,thanks")
        original = try await controller.applyVoiceCommands(original)
        XCTAssertEqual(original.correctedText, "please shared clipboard ,thanks")
        let options = DesktopPostProcessing.Options(mode: .local, modelIdentifier: rules)
        let result = await controller.postProcess(original, options: options)
        XCTAssertEqual(effects.requests.first?.text, original.correctedText)
        XCTAssertEqual(effects.requests.first?.key, "")
        XCTAssertEqual(result.originalText, "please copy pasta ,thanks")
        XCTAssertEqual(result.processedText, "Please shared clipboard, thanks")
        XCTAssertEqual(result.postProcessingModelIdentifier, rules)
        XCTAssertNil(result.postProcessingFailure)
        try await controller.store.save(result)
        let restored = try await controller.store.records()
        XCTAssertEqual(restored.first?.postProcessingModelIdentifier, rules)
        XCTAssertEqual(restored.first?.processedText, result.processedText)
        XCTAssertTrue(DesktopHistoryRowSummary(result).models.contains(ModelCatalog.friendlyName(for: rules)))
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(probe.writes, 0)
    }

    func testLocalSilenceNeverCallsEffectsOrCredentials() async {
        let probe = observeCredentials()
        for text in ["", " \t\n", "[blank_audio]", " [BLANK_AUDIO] [blank_audio] "] {
            let result = await controller.postProcess(
                record(text), options: .init(mode: .local, modelIdentifier: rules)
            )
            XCTAssertEqual(result.processedText, "")
            XCTAssertNil(result.postProcessingModelIdentifier)
        }
        XCTAssertTrue(effects.requests.isEmpty)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(probe.writes, 0)
    }

    func testUnsupportedLocalCannotReadKeysOrInvokeEffects() async {
        let probe = observeCredentials()
        let result = await controller.postProcess(record("hello"), options: .init(
            mode: .local, modelIdentifier: "local/post-processing/downloaded"
        ))
        XCTAssertNotNil(result.postProcessingFailure)
        XCTAssertNil(result.processedText)
        XCTAssertNil(result.postProcessingModelIdentifier)
        XCTAssertTrue(effects.requests.isEmpty)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(probe.writes, 0)
    }

    func testCancellationRejectsAlreadyComputedLocalResult() async throws {
        effects.gate = Gate(open: false)
        let probe = observeCredentials()
        let original = record("hello")
        let options = DesktopPostProcessing.Options(mode: .local, modelIdentifier: rules)
        let controller = try XCTUnwrap(controller)
        await controller.beginBusyOperation()
        let task = Task {
            let result = await controller.postProcess(original, options: options)
            await controller.finishBusyOperation()
            return result
        }
        await effects.entered.pass()
        await controller.cancelTranscription()
        let result = await task.value
        XCTAssertNotNil(result.postProcessingFailure)
        XCTAssertNil(result.processedText)
        XCTAssertNil(result.postProcessingModelIdentifier)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(probe.writes, 0)
    }
}

extension DesktopHostLocalRulesTests {
    func testJSONImportExportLocalExecutionAndDisabledRestartWithoutCredentialPermission() async throws {
        let probe = observeCredentials()
        let file = directory.appendingPathComponent("local.json")
        for flag in [true, false] {
            let preferences = try DesktopConfiguration(values: [
                ApplicationPreferenceKey.postProcessingModel.rawValue: AnyCodable(.string(rules)),
                ApplicationPreferenceKey.postProcessingEnabled.rawValue: AnyCodable(.bool(flag)),
                DesktopPostProcessingConfiguration.customPromptKey: AnyCodable(.string("Remote prompt kept.")),
                ApplicationPreferenceKey.postProcessingIncludeLexiconDirectives.rawValue: AnyCodable(.bool(false)),
                ApplicationPreferenceKey.postProcessingIncludeContextTags.rawValue: AnyCodable(.bool(true)),
                ApplicationPreferenceKey.postProcessingTemperature.rawValue:
                    AnyCodable(.double(SpeechDefaults.temperature)),
                ApplicationPreferenceKey.postProcessingOutputLanguage.rawValue: AnyCodable(.string("")),
                "unsupportedApplePreference": AnyCodable(.string("retained"))
            ])
            try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences)).write(to: file)
            try await controller.importConfiguration(path: file.path)
            let applied = await controller.postProcessingOptions()
            XCTAssertEqual(applied.mode, flag ? .local : .disabled)
            let result = await controller.postProcess(record("hello  world ,friend"), options: applied)
            XCTAssertEqual(result.processedText, flag ? "Hello world, friend" : nil)
            let configuration = try await controller.configuration()
            XCTAssertTrue(DesktopPostProcessingConfiguration.keys.isDisjoint(with: configuration.values.keys))
            try await controller.exportConfiguration(path: file.path)
            let exported = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: file))
            XCTAssertEqual(exported.preferences, preferences)
            await controller.close()
            controller = try DesktopHostController(directory: directory, effects: effects)
            let restarted = await controller.postProcessingOptions()
            XCTAssertEqual(restarted, applied)
        }
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(probe.writes, 0)
    }

    func testRefusedLocalSaveAndImportLeaveRuntimeAndDiskUnchanged() async throws {
        await controller.savePostProcessing(enabled: false, modelIdentifier: rules, prompt: "", key: "")
        let original = await controller.postProcessingOptions()
        let settings = directory.appendingPathComponent("settings.json")
        let before = try Data(contentsOf: settings)
        effects.refusesSettings = true
        await controller.savePostProcessing(enabled: true, modelIdentifier: rules, prompt: "", key: "ignored")
        let unchanged = await controller.postProcessingOptions()
        XCTAssertEqual(unchanged, original)
        XCTAssertEqual(try Data(contentsOf: settings), before)
        let file = directory.appendingPathComponent("refused.json")
        let preferences = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.postProcessingModel.rawValue: AnyCodable(.string(rules)),
            ApplicationPreferenceKey.postProcessingEnabled.rawValue: AnyCodable(.bool(true))
        ])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences)).write(to: file)
        do { try await controller.importConfiguration(path: file.path); XCTFail("Refused import succeeded") } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let afterImport = await controller.postProcessingOptions()
        XCTAssertEqual(afterImport, original)
        XCTAssertEqual(try Data(contentsOf: settings), before)
    }

    func testUnsupportedLocalImportDisablesRemoteAndRetainsRequestedValues() async throws {
        await controller.savePostProcessing(
            enabled: true, modelIdentifier: ModelCatalog.defaultPostProcessingModel, prompt: "", key: ""
        )
        let probe = observeCredentials()
        let file = directory.appendingPathComponent("unsupported.json")
        let preferences = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.postProcessingModel.rawValue: AnyCodable(.string("local/post-processing/unknown")),
            ApplicationPreferenceKey.postProcessingEnabled.rawValue: AnyCodable(.bool(true))
        ])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences)).write(to: file)
        try await controller.importConfiguration(path: file.path)
        let options = await controller.postProcessingOptions()
        XCTAssertEqual(options.mode, .disabled)
        XCTAssertEqual(options.modelIdentifier, "local/post-processing/unknown")
        let result = await controller.postProcess(record("hello"), options: options)
        XCTAssertNil(result.processedText)
        XCTAssertTrue(effects.requests.isEmpty)
        try await controller.exportConfiguration(path: file.path)
        let exported = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: file))
        for key in [ApplicationPreferenceKey.postProcessingModel, .postProcessingEnabled] {
            XCTAssertEqual(exported.preferences.values[key.rawValue], preferences.values[key.rawValue])
        }
        await controller.close()
        controller = try DesktopHostController(directory: directory, effects: effects)
        let restarted = await controller.postProcessingOptions()
        XCTAssertEqual(restarted.mode, .disabled)
        XCTAssertEqual(restarted.modelIdentifier, options.modelIdentifier)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(probe.writes, 0)
    }
}
