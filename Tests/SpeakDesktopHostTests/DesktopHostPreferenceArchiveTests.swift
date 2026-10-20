import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

extension FakePlatform {
    static var nativeConfigurationPlatform: DesktopNativeConfigurationCapture.Platform? { .windows }

    static func archiveNativePreferences(
        textOutput: FakeTextOutput?, hotKey: FakeHotKey?, voiceOutput: DesktopVoiceOutputSettings?
    ) -> DesktopHostNativePreferenceProjection {
        var result = DesktopHostNativePreferenceProjection()
        result.voice(voiceOutput)
        if textOutput != nil { result.nativeOnly("textOutput") }
        if hotKey != nil { result.nativeOnly("hotKey") }
        return result
    }
}

final class DesktopHostPreferenceArchiveTests: XCTestCase {
    private typealias Settings = DesktopHostController<FakePlatform>.Settings
    private let categories: Set<DataMigrationCategory> = [.settings, .vocabulary, .connections]

    private func records(_ settings: Settings) throws -> [String: AnyCodable] {
        let result = try DesktopHostPreferenceArchive.project(settings, categories: categories)
        return Dictionary(uniqueKeysWithValues: result.records.values.flatMap { $0 }.map { ($0.id, $0.value) })
    }

    func testNewSettings_HasNoExplicitPreferencesOrInventedVoiceDefaults() throws {
        let settings = Settings()
        XCTAssertTrue(try records(settings).isEmpty)
        var withVoice = settings
        withVoice.voiceOutput = DesktopVoiceOutputSettings()
        XCTAssertTrue(try records(withVoice).isEmpty)
    }

    func testSharedNativeAuthorities_OverrideStaleMirrorsWithoutMutation() throws {
        var settings = Settings()
        settings.configuration = try DesktopConfiguration(values: [
            "batchTranscriptionModel": AnyCodable(.string("old/batch")),
            "appearance": AnyCodable(.string("light")), "enableAutomationServer": AnyCodable(.bool(true)),
            "postProcessingTemperature": AnyCodable(.double(0.1)),
            "postProcessingOutputLanguage": AnyCodable(.string("German"))
        ])
        settings.batchModel = "stored/batch"
        settings.liveModel = "stored/live"
        settings.localModel = "local/transcribe.cpp/test"
        settings.appearance = .dark
        settings.runAtLogin = false
        settings.automationEnabled = false
        settings.postProcessing = .init(mode: .remote, modelIdentifier: "stored/polish",
                                       outputLanguage: "French", temperature: 0.7)
        let before = try JSONEncoder().encode(settings)
        let result = try records(settings)
        XCTAssertEqual(result["batchTranscriptionModel"], AnyCodable(.string("stored/batch")))
        XCTAssertEqual(result["liveTranscriptionModel"], AnyCodable(.string("stored/live")))
        XCTAssertEqual(result["localTranscriptionModel"], AnyCodable(.string("local/transcribe.cpp/test")))
        XCTAssertEqual(result["appearance"], AnyCodable(.string("dark")))
        XCTAssertEqual(result["runAtLogin"], AnyCodable(.bool(false)))
        XCTAssertEqual(result["enableAutomationServer"], AnyCodable(.bool(false)))
        XCTAssertEqual(result["postProcessingEnabled"], AnyCodable(.bool(true)))
        XCTAssertEqual(result["postProcessingModel"], AnyCodable(.string("stored/polish")))
        XCTAssertEqual(result["postProcessingTemperature"], AnyCodable(.double(0.7)))
        XCTAssertEqual(result["postProcessingOutputLanguage"], AnyCodable(.string("French")))
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: before).configuration, settings.configuration)
        XCTAssertEqual(settings.configuration?.values["appearance"], AnyCodable(.string("light")))
    }

    func testActiveModel_UsesCanonicalFamilyAndIsNotASecondDefault() throws {
        let cases: [String: (mode: String, key: String)] = [
            ModelCatalog.defaultBatchTranscriptionModel: ("batchRemote", "batchTranscriptionModel"),
            "local/transcribe.cpp/test": ("localModel", "localTranscriptionModel")
        ]
        for (model, projection) in cases {
            var settings = Settings()
            settings.model = model
            let result = try records(settings)
            XCTAssertEqual(result["transcriptionMode"], AnyCodable(.string(projection.mode)))
            XCTAssertEqual(result[projection.key], AnyCodable(.string(model)))
        }
        let live = try XCTUnwrap(ModelCatalog.liveTranscription.first {
            if case .cloudStreaming = ModelRouting.family(for: $0.id) { return true }
            return false
        })
        var settings = Settings()
        settings.model = live.id
        XCTAssertEqual(try records(settings)["transcriptionMode"], AnyCodable(.string("liveNative")))
    }

    func testUnknownActiveModel_IsExplicitlyUnprojectableNotBatchFallback() throws {
        var settings = Settings()
        settings.model = "future/provider"
        settings.configuration = try DesktopConfiguration(values: [
            "transcriptionMode": AnyCodable(.string("batchRemote"))
        ])
        let result = try DesktopHostPreferenceArchive.project(settings, categories: categories)
        XCTAssertTrue(result.records.values.allSatisfy(\.isEmpty))
        XCTAssertTrue(result.notices.contains(.init(path: "model", reason: .nativeOnly)))
        XCTAssertTrue(result.notices.contains(.init(path: "configuration.transcriptionMode", reason: .shadowed)))
    }

    func testRuntimeModelNormalization_PreservesExplicitSlotPresence() throws {
        var settings = Settings()
        settings.liveModel = "stored/live"
        settings.preservingArchiveModelPresence {
            $0.model = ModelCatalog.defaultBatchTranscriptionModel
            $0.batchModel = ModelCatalog.defaultBatchTranscriptionModel
            $0.liveModel = "migrated/live"
            $0.localModel = "local/transcribe.cpp/test"
            $0.localLiveModel = "local/streaming/whisperkit/tiny"
        }
        XCTAssertEqual(try records(settings), ["liveTranscriptionModel": AnyCodable(.string("migrated/live"))])
        settings.model = ModelCatalog.defaultBatchTranscriptionModel
        XCTAssertEqual(try records(settings)["transcriptionMode"], AnyCodable(.string("batchRemote")))
    }

    func testVoiceExplicitFields_AreSoleAuthorityWithoutExecutionOrClamping() throws {
        var settings = Settings()
        settings.configuration = try DesktopConfiguration(values: [
            "ttsAutoPlay": AnyCodable(.bool(true)), "ttsSpeed": AnyCodable(.double(1.5))
        ])
        var voice = DesktopVoiceOutputSettings(modelID: "unavailable/provider", voiceID: "unavailable/voice")
        voice.autoPlay = false
        voice.saveToRecordings = false
        voice.speed = 0.25
        voice.pitch = -30
        voice.useSSML = false
        voice.trackUsage = false
        settings.voiceOutput = voice
        let result = try records(settings)
        XCTAssertEqual(result["ttsAutoPlay"], AnyCodable(.bool(false)))
        XCTAssertEqual(result["ttsSaveToDirectory"], AnyCodable(.bool(false)))
        XCTAssertEqual(result["ttsSpeed"], AnyCodable(.double(0.25)))
        XCTAssertEqual(result["ttsPitch"], AnyCodable(.double(-30)))
        XCTAssertEqual(result["ttsUseSSML"], AnyCodable(.bool(false)))
        XCTAssertNil(result["defaultTTSVoice"])
        XCTAssertEqual(settings.voiceOutput, voice)
        XCTAssertEqual(settings.configuration?.values["ttsSpeed"], AnyCodable(.double(1.5)))
        let projection = try DesktopHostPreferenceArchive.project(settings, categories: categories)
        for path in ["voiceOutput.modelID", "voiceOutput.voiceID", "voiceOutput.ttsTrackUsage"] {
            XCTAssertTrue(projection.notices.contains(.init(path: path, reason: .nativeOnly)))
        }
    }

    func testHeadNativeAuthorities_ProjectExplicitNativeFields() throws {
        var settings = Settings()
        var polish = DesktopPostProcessing.Options(mode: .remote, modelIdentifier: "stored/polish")
        polish.includeLexiconDirectives = false
        polish.includeContextTags = false
        polish.streamingEnabled = false
        settings.postProcessing = polish
        var voice = DesktopVoiceOutputSettings()
        voice.favoriteVoices = ["voice/b", "voice/a", "voice/b"]
        voice.language = "fr"
        voice.strictVoiceSelection = true
        settings.voiceOutput = voice
        let result = try records(settings)
        XCTAssertEqual(result["postProcessingIncludeLexiconDirectives"], AnyCodable(.bool(false)))
        XCTAssertEqual(result["postProcessingIncludeContextTags"], AnyCodable(.bool(false)))
        XCTAssertEqual(result["postProcessingStreamingEnabled"], AnyCodable(.bool(false)))
        XCTAssertEqual(result["ttsFavoriteVoices"], VoiceFavoritePreference.encoded(["voice/b", "voice/a", "voice/b"]))
        XCTAssertEqual(result["ttsLanguage"], AnyCodable(.string("fr")))
        let projection = try DesktopHostPreferenceArchive.project(settings, categories: categories)
        XCTAssertTrue(projection.notices.contains(.init(path: "voiceOutput.strictVoiceSelection", reason: .nativeOnly)))
    }

    func testAbsentVoiceFields_PreserveLegacyValuesAndNoOtherDefaults() throws {
        var settings = Settings()
        settings.voiceOutput = DesktopVoiceOutputSettings()
        settings.configuration = try DesktopConfiguration(values: ["ttsSpeed": AnyCodable(.double(1.25))])
        XCTAssertEqual(try records(settings), ["ttsSpeed": AnyCodable(.double(1.25))])
    }

    func testAbsentNativeLanguage_ShadowsStaleMirrorWithoutInventingEmptyText() throws {
        var settings = Settings()
        settings.configuration = try DesktopConfiguration(values: [
            "postProcessingOutputLanguage": AnyCodable(.string("German"))
        ])
        settings.postProcessing = .init()
        XCTAssertNil(try records(settings)["postProcessingOutputLanguage"])
        settings.postProcessing?.outputLanguage = ""
        XCTAssertEqual(try records(settings)["postProcessingOutputLanguage"], AnyCodable(.string("")))
    }

    func testUnknownWrapperAndNativeOnlyFields_AreNamedNotSerialized() throws {
        let value: [String: AnyCodable] = [
            "model": AnyCodable(.string(ModelCatalog.defaultBatchTranscriptionModel)),
            "futureRoot": AnyCodable(.object(["opaque": .string("private")])),
            "microphoneDeviceID": AnyCodable(.string("native-id")),
            "localUseGPU": AnyCodable(.bool(false)),
            "azureSpeechResourceEndpoint": AnyCodable(.string("https://private.invalid"))
        ]
        let settings = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(value))
        let result = try DesktopHostPreferenceArchive.project(settings, categories: categories)
        XCTAssertTrue(result.notices.contains(.init(path: "futureRoot", reason: .unknownPreference)))
        for path in ["microphoneDeviceID", "localUseGPU", "azureSpeechResourceEndpoint"] {
            XCTAssertTrue(result.notices.contains(.init(path: path, reason: .nativeOnly)))
            XCTAssertNil(try records(settings)[path])
        }
        let retained = try JSONDecoder().decode([String: AnyCodable].self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(retained["futureRoot"], value["futureRoot"])
    }

    func testActivation_ExportsOnlyExactMacStylesAndNeverFallbacks() {
        for style in HotKeyActivationStyle.allCases.map(\.rawValue) + ["future-style"] {
            var projection = DesktopHostNativePreferenceProjection()
            projection.activation(style)
            if HotKeyActivationStyle.macOSStyles.contains(where: { $0.rawValue == style }) {
                XCTAssertEqual(projection.values["hotKeyActivation"], AnyCodable(.string(style)))
            } else {
                XCTAssertTrue(projection.values.isEmpty)
                XCTAssertEqual(projection.suppressedKeys, ["hotKeyActivation"])
                XCTAssertEqual(projection.notices, [.init(path: "hotKey.style", reason: .nativeOnly)])
            }
        }
    }

    func testInvalidNativeScalar_FailsWithoutMutatingSettings() throws {
        var settings = Settings()
        var voice = DesktopVoiceOutputSettings()
        voice.speed = .infinity
        settings.voiceOutput = voice
        XCTAssertThrowsError(try records(settings))
        XCTAssertEqual(settings.voiceOutput?.speed, .infinity)
    }

    func testActualControllerProjection_IsReadOnlyAndCategoryBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let effects = SettingsWriteEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        let before = await controller.settings
        let projected = try await controller.preferenceArchiveProjection(categories: [.vocabulary])
        let all = try await controller.preferenceArchiveProjection(categories: categories)
        let after = await controller.settings
        await controller.close()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(Set(projected.records.keys), [.vocabulary])
        XCTAssertEqual(projected.records[.vocabulary], [])
        XCTAssertTrue(all.records.values.allSatisfy(\.isEmpty))
        XCTAssertEqual(effects.writes, 0)
        XCTAssertEqual(try DataMigrationCoding.value(before), try DataMigrationCoding.value(after))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.json").path))
    }
}
