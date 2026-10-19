import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostModulateConfigurationTests: XCTestCase {
    func testRootStartupAndNestedPrecedence_ExportRestartAndNativeClear() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let speaker = ApplicationPreferenceKey.modulateSpeakerDiarization.rawValue
        let emotion = ApplicationPreferenceKey.modulateEmotionSignal.rawValue
        let settings: [String: AnyCodable] = [
            "model": AnyCodable(.string(ModelCatalog.defaultBatchTranscriptionModel)),
            speaker: AnyCodable(.string("ignored root shadow")), emotion: AnyCodable(.bool(true)),
            "configuration": AnyCodable(.object([speaker: .bool(false)]))
        ]
        let settingsFile = root.appendingPathComponent("settings.json")
        try JSONEncoder().encode(settings).write(to: settingsFile)
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let configuration = try await controller.configuration()
        XCTAssertEqual(configuration.liveOptions.modulate, ModulateLiveOptions(emotionSignal: true))
        try await controller.saveConfiguration(configuration.entries)
        let export = root.appendingPathComponent("modulate.json")
        try await controller.exportConfiguration(path: export.path)
        let exported = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: export))
        XCTAssertEqual(exported.preferences.values[speaker], AnyCodable(.bool(false)))
        XCTAssertEqual(exported.preferences.values[emotion], AnyCodable(.bool(true)))
        await controller.close()
        let restarted = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let restored = try await restarted.configuration()
        XCTAssertEqual(restored.liveOptions.modulate, configuration.liveOptions.modulate)
        XCTAssertEqual(restored.modulateBatchFeatures, configuration.modulateBatchFeatures)
        var entries = restored.entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == emotion })
        entries[index] = "0"
        try await restarted.saveConfiguration(entries)
        let cleared = try await restarted.configuration()
        XCTAssertEqual(cleared.liveOptions.modulate, .none)
        XCTAssertEqual(cleared.modulateBatchFeatures, .init(speakerDiarization: false))
        entries[index] = ""
        let speakerIndex = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == speaker })
        entries[speakerIndex] = ""
        try await restarted.saveConfiguration(entries)
        let legacy = try await restarted.configuration()
        XCTAssertNil(legacy.values[speaker])
        XCTAssertNil(legacy.values[emotion])
        XCTAssertEqual(legacy.liveOptions.modulate, .none)
        XCTAssertEqual(legacy.modulateBatchFeatures, .init())
        await restarted.close()
    }

    func testMalformedRootPreferences_AreRejectedInsteadOfCoercedOrSilentlyPreserved() throws {
        for key in DesktopConfiguration.modulatePreferenceKeys {
            let settings: [String: AnyCodable] = [
                "model": AnyCodable(.string(ModelCatalog.defaultBatchTranscriptionModel)),
                key: AnyCodable(.string("true"))
            ]
            XCTAssertThrowsError(try JSONDecoder().decode(
                DesktopHostController<FakePlatform>.Settings.self, from: JSONEncoder().encode(settings)
            ))
        }
    }

    func testImportAndRefusedApply_PreserveSelectionDiskAndOtherApprovalBoundaries() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = SettingsWriteEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        var values = Dictionary(uniqueKeysWithValues: DesktopConfiguration.modulatePreferenceKeys.map {
            ($0, AnyCodable(.bool(true)))
        })
        values["futureProviderControl"] = AnyCodable(.string("kept"))
        let imported = try DesktopConfiguration(values: values)
        let file = root.appendingPathComponent("modulate-import.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: imported)).write(to: file)
        try await controller.importConfiguration(path: file.path)
        let before = try await controller.configuration()
        let selected = await controller.settings.model
        let approval = await controller.settings.livePolishApproved
        XCTAssertNotEqual(approval, true)
        let disk = root.appendingPathComponent("settings.json")
        let original = try Data(contentsOf: disk)
        var entries = before.entries
        for key in DesktopConfiguration.modulatePreferenceKeys {
            let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
            entries[index] = "0"
        }
        effects.refusesWrites = true
        do {
            try await controller.saveConfiguration(entries)
            XCTFail("A refused write changed Modulate feature options.")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let after = try await controller.configuration()
        let retainedModel = await controller.settings.model
        XCTAssertEqual(after, before)
        XCTAssertEqual(retainedModel, selected)
        XCTAssertEqual(try Data(contentsOf: disk), original)
        XCTAssertEqual(after.values["futureProviderControl"], AnyCodable(.string("kept")))
        await controller.close()
    }

    func testComparisonAdmission_CapturesFeaturesBeforeLaterChanges() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let model = "modulate/velma-2-stt"
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic", name: credential)
        let otherModel = "openai/whisper-1"
        let otherCredential = try XCTUnwrap(DesktopHostModels.provider(for: otherModel)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic", name: otherCredential)
        var entries = try await controller.configuration().entries
        for key in DesktopConfiguration.modulatePreferenceKeys {
            let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
            entries[index] = "1"
        }
        try await controller.saveConfiguration(entries)
        let batch = try await controller.comparisonAdmission(
            [model, otherModel], live: false, language: nil, generation: UUID()
        )
        for key in DesktopConfiguration.modulatePreferenceKeys {
            let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
            entries[index] = "0"
        }
        try await controller.saveConfiguration(entries)
        XCTAssertEqual(batch.modulateBatch, .init(
            speakerDiarization: true, emotionSignal: true, accentSignal: true, piiPhiTagging: true
        ))
        XCTAssertEqual(batch.modulateLive, .init(
            speakerDiarization: true, emotionSignal: true, accentSignal: true, piiPhiTagging: true
        ))
        let current = try await controller.configuration()
        XCTAssertEqual(current.modulateBatchFeatures, .init(speakerDiarization: false))
        await controller.close()
    }
}
