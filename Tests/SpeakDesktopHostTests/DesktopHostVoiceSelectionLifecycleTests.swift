import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceSelectionLifecycleTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var effects: SettingsWriteEffects!
    private let access = VoiceSelectionAccessProbe()

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        access.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-selection-\(UUID())")
        effects = SettingsWriteEffects()
        controller = try DesktopHostController(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        let access = access
        FakeLog.shared.installKeyReadHook { _ in access.record(0) }
    }

    override func tearDown() async throws {
        await controller.close()
        FakeLog.shared.reset()
        try FileManager.default.removeItem(at: directory)
    }

    private func importValues(_ values: [String: AnyCodable]) async throws {
        let path = directory.appendingPathComponent("selection-import.json")
        let document = try DesktopConfigurationDocument(preferences: DesktopConfiguration(values: values))
        try JSONEncoder().encode(document).write(to: path)
        try await controller.importConfiguration(path: path.path)
    }

    func testScalarImportExportRestart_ChangesTheNativeAuthorityWithoutReadingKeys() async throws {
        try await importValues(["defaultTTSVoice": AnyCodable(.string("openai/alloy"))])
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.modelID, OpenAITTSCatalog.defaultModel.desktopModelIdentifier)
        XCTAssertEqual(saved.voiceID, "openai/alloy")
        XCTAssertEqual(saved.strictVoiceSelection, true)
        let remaining = try await controller.configuration()
        XCTAssertTrue(VoiceSelectionPreference.keys.isDisjoint(with: remaining.values.keys))
        let export = directory.appendingPathComponent("selection-export.json")
        try await controller.exportConfiguration(path: export.path)
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: export))
        XCTAssertEqual(document.preferences.values["defaultTTSVoice"], AnyCodable(.string("openai/alloy")))
        XCTAssertEqual(document.preferences.values[VoiceSelectionPreference.modelKey],
                       saved.modelID.map { AnyCodable(.string($0)) })
        await controller.close()
        controller = try DesktopHostController(directory: directory, effects: effects)
        let restarted = await controller.voiceOutputSettings()
        XCTAssertEqual(restarted, saved)
        XCTAssertEqual(access.counts, [0, 0, 0])
    }

    func testAdvancedNativeSelection_ExportScalarAndEditorRetainExplicitModelQualityAndFormat() async throws {
        let voice = try XCTUnwrap(DesktopSpeechVoice.voices.first {
            if case .openai(let model, _) = $0 { return model != OpenAITTSCatalog.defaultModel }
            return false
        })
        await controller.selectVoiceOutput(voice)
        var original = await controller.voiceOutputSettings()
        original.format = "m4a"; original.sonioxRegion = "future-region"
        await controller.saveVoiceOutput(original)
        let path = directory.appendingPathComponent("advanced-export.json")
        try await controller.exportConfiguration(path: path.path)
        try await controller.importConfiguration(path: path.path)
        try await importValues(["defaultTTSVoice": AnyCodable(.string(voice.transferVoiceID))])
        let editor = try await controller.configurationForNativeEditor()
        try await controller.saveConfiguration(editor.entries, intent: .persistOnly)
        let after = await controller.voiceOutputSettings()
        XCTAssertEqual(after.modelID, original.modelID)
        XCTAssertEqual(after.voiceID, original.voiceID)
        XCTAssertEqual(after.quality, original.quality)
        XCTAssertEqual(after.format, original.format)
        XCTAssertEqual(after.sonioxRegion, original.sonioxRegion)
        XCTAssertEqual(try after.synthesisSelection().voice, try original.synthesisSelection().voice)
        XCTAssertEqual(access.counts, [0, 0, 0])
    }

    func testExplicitUnsupportedImports_RefuseReadGenerateFreshExportAndSelectedKeyBeforeAnyAccess() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic unavailable voice.")
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 24_000))
        let destination = directory.deletingLastPathComponent().appendingPathComponent("refused-\(UUID()).wav")
        let access = access
        for raw in ["future", "deepgram/future", "apple/local/en-US", "openrouter/future/model/voice",
                    "mistral/account-only", "xai/account-only", "soniox/future", "openai/future"] {
            try await importValues(["defaultTTSVoice": AnyCodable(.string(raw))])
            await controller.readVoiceSource(source)
            await controller.generateVoiceSource(source, options: .init(autoPlay: false, saveToRecordings: false)) {
                _, _, credential in
                access.record(1); _ = try await credential(); return wav
            }
            await controller.exportVoiceSource(source, path: destination.path, synthesize: { _, _, credential in
                access.record(1); _ = try await credential(); return wav
            }, publish: { _, _ in access.record(2) })
            let key = await controller.voiceCredentialPresentation()
            guard case .failure(.unavailable) = key else { return XCTFail("Unavailable intent exposed a key slot.") }
            let generation = await controller.voiceGenerationTask
            let export = await controller.readAloudState.exportTask
            let read = await controller.readAloudState.task
            XCTAssertNil(generation); XCTAssertNil(export); XCTAssertNil(read)
            let saved = await controller.voiceOutputSettings()
            XCTAssertEqual(saved.voiceID, raw)
            XCTAssertEqual(saved.strictVoiceSelection, true)
        }
        XCTAssertEqual(access.counts, [0, 0, 0])
        XCTAssertTrue(FakeSpeech.shared.spoken.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFailedImportAndNativeChoice_KeepUnavailableIntentFileEpochAndRevisionAtomic() async throws {
        try await importValues(["defaultTTSVoice": AnyCodable(.string(" Future/Case Voice "))])
        let saved = await controller.voiceOutputSettings()
        let epoch = await controller.voiceCredentialEpoch
        let revision = await controller.voiceSettingsRevision
        let settingsURL = directory.appendingPathComponent("settings.json")
        let disk = try Data(contentsOf: settingsURL)
        for key in VoiceSelectionPreference.keys {
            do {
                try await importValues([key: AnyCodable(.bool(true)), "ttsAutoPlay": AnyCodable(.bool(false))])
                XCTFail("Malformed selection was accepted.")
            } catch is DesktopConfigurationError {}
        }
        effects.refusesWrites = true
        do {
            try await importValues(["defaultTTSVoice": AnyCodable(.string("openai/alloy"))])
            XCTFail("Failed write was accepted.")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue) }
        let voice = try XCTUnwrap(DesktopSpeechVoice.voices.first)
        await controller.selectVoiceOutput(voice)
        let unchanged = await controller.voiceOutputSettings()
        let unchangedEpoch = await controller.voiceCredentialEpoch
        let unchangedRevision = await controller.voiceSettingsRevision
        XCTAssertEqual(unchanged, saved)
        XCTAssertEqual(unchangedEpoch, epoch); XCTAssertEqual(unchangedRevision, revision)
        XCTAssertEqual(try Data(contentsOf: settingsURL), disk)
        effects.refusesWrites = false
        await controller.selectVoiceOutput(voice)
        let replaced = await controller.voiceOutputSettings()
        XCTAssertNil(replaced.strictVoiceSelection)
        XCTAssertEqual(replaced.modelID, voice.modelID); XCTAssertEqual(replaced.voiceID, voice.id)
        XCTAssertNoThrow(try replaced.synthesisSelection())
        XCTAssertEqual(access.counts, [0, 0, 0])
    }
}

final class VoiceSelectionAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [0, 0, 0]
    var counts: [Int] { lock.withLock { values } }
    func record(_ index: Int) { lock.withLock { values[index] += 1 } }
    func reset() { lock.withLock { values = [0, 0, 0] } }
}
