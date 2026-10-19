import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceSelectionStartupTests: XCTestCase {
    func testRawRootAndCanonicalNestedStartup_ProjectOnceWithNestedPrecedenceAndExplicitQuality() async throws {
        FakeLog.shared.reset()
        let access = VoiceSelectionAccessProbe()
        FakeLog.shared.installKeyReadHook { _ in access.record(0) }
        defer { FakeLog.shared.reset() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-startup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for nested in [false, true] {
            let directory = root.appendingPathComponent(nested ? "nested" : "root")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var settings = DesktopHostController<FakePlatform>.Settings()
            if nested {
                settings.configuration = try DesktopConfiguration(values: [
                    VoiceSelectionPreference.key: AnyCodable(.string("openai/alloy")),
                    VoiceSelectionPreference.modelKey:
                        AnyCodable(.string(OpenAITTSModel.highDefinition.desktopModelIdentifier)),
                    "ttsQuality": AnyCodable(.string("highest"))
                ])
            }
            var raw = try JSONDecoder().decode([String: AnyCodable].self, from: JSONEncoder().encode(settings))
            raw[VoiceSelectionPreference.key] = AnyCodable(.string(nested ? "future/root" : "openai/alloy"))
            raw["ttsQuality"] = AnyCodable(.string("high"))
            try JSONEncoder().encode(raw).write(to: directory.appendingPathComponent("settings.json"))
            let controller = try DesktopHostController<FakePlatform>(
                directory: directory, effects: SettingsWriteEffects())
            let saved = await controller.voiceOutputSettings()
            XCTAssertEqual(saved.voiceID, "openai/alloy")
            XCTAssertEqual(saved.modelID, nested ? OpenAITTSModel.highDefinition.desktopModelIdentifier
                : OpenAITTSCatalog.defaultModel.desktopModelIdentifier)
            XCTAssertEqual(saved.quality, nested ? "highest" : "high")
            XCTAssertEqual(saved.strictVoiceSelection, true)
            let configuration = try await controller.configuration()
            XCTAssertTrue(VoiceSelectionPreference.keys.isDisjoint(with: configuration.values.keys))
            XCTAssertNil(configuration.values["ttsQuality"])
            await controller.saveVoiceOutput(saved)
            let disk = try JSONDecoder().decode([String: AnyCodable].self,
                from: Data(contentsOf: directory.appendingPathComponent("settings.json")))
            XCTAssertNil(disk[VoiceSelectionPreference.key])
            XCTAssertNil(disk[VoiceSelectionPreference.modelKey])
            XCTAssertNil(disk["ttsQuality"])
            await controller.close()
        }
        XCTAssertEqual(access.counts, [0, 0, 0])
    }

    func testUnknownStartupAndMissingSelection_PreserveRawIntentWithoutMaterializingDefault() throws {
        var missing = DesktopHostController<FakePlatform>.Settings()
        try DesktopHostController<FakePlatform>.importStoredVoiceSelection(into: &missing)
        XCTAssertNil(missing.voiceOutput)
        var explicit = DesktopHostController<FakePlatform>.Settings()
        let rawVoice = " Future/Case\tVoice "
        let rawModel = " Future/Model "
        explicit.configuration = try DesktopConfiguration(values: [
            VoiceSelectionPreference.key: AnyCodable(.string(rawVoice)),
            VoiceSelectionPreference.modelKey: AnyCodable(.string(rawModel))
        ])
        try DesktopHostController<FakePlatform>.importStoredVoiceSelection(into: &explicit)
        let voice = try XCTUnwrap(explicit.voiceOutput)
        XCTAssertEqual(voice.voiceID, rawVoice)
        XCTAssertEqual(voice.modelID, rawModel)
        XCTAssertEqual(voice.strictVoiceSelection, true)
        XCTAssertThrowsError(try voice.synthesisSelection())
        let restarted = try JSONDecoder().decode(DesktopHostController<FakePlatform>.Settings.self,
            from: JSONEncoder().encode(explicit))
        XCTAssertEqual(restarted.voiceOutput, voice)
        XCTAssertTrue(VoiceSelectionPreference.keys.isDisjoint(
            with: try XCTUnwrap(restarted.configuration).values.keys))
    }

    func testUnbridgedHost_PreservesRootAndNestedSelectionAndQualityWithoutApplying() throws {
        var settings = DesktopHostController<FakeLocalPlatform>.Settings()
        settings.configuration = try DesktopConfiguration(values: [
            VoiceSelectionPreference.key: AnyCodable(.string("future/nested")),
            VoiceSelectionPreference.modelKey: AnyCodable(.string("future-model")),
            "ttsQuality": AnyCodable(.string("future-quality"))
        ])
        var raw = try JSONDecoder().decode([String: AnyCodable].self, from: JSONEncoder().encode(settings))
        raw[VoiceSelectionPreference.key] = AnyCodable(.string("apple/local/en-US"))
        raw["ttsQuality"] = AnyCodable(.string("high"))
        var decoded = try JSONDecoder().decode(DesktopHostController<FakeLocalPlatform>.Settings.self,
            from: JSONEncoder().encode(raw))
        try DesktopHostController<FakeLocalPlatform>.importStoredVoiceSelection(into: &decoded)
        XCTAssertNil(decoded.voiceOutput)
        XCTAssertEqual(decoded.configuration, settings.configuration)
        let exported = try JSONDecoder().decode([String: AnyCodable].self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(exported[VoiceSelectionPreference.key], raw[VoiceSelectionPreference.key])
        XCTAssertEqual(exported["ttsQuality"], raw["ttsQuality"])
    }
}
