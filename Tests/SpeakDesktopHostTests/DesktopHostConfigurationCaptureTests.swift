import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostConfigurationCaptureTests: XCTestCase {
    private typealias Settings = DesktopHostController<FakePlatform>.Settings
    private typealias Field = DesktopNativeConfigurationField
    private let categories: Set<DataMigrationCategory> = [.settings, .vocabulary, .connections]

    private func capture(_ settings: Settings, fields: [Field] = []) throws -> DesktopHostConfigurationCapture {
        try .capture(settings, categories: categories, selectedNativeFields: Set(fields.map(\.rawValue)))
    }

    private func decode(_ value: [String: AnyCodable]) throws -> Settings {
        var stored = value
        stored["model"] = AnyCodable(.string(ModelCatalog.defaultBatchTranscriptionModel))
        return try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(stored))
    }

    func testDistinctPromptOwners_PreserveRawTextAndCanonicalRecords() throws {
        var settings = Settings()
        settings.postProcessing = .init(mode: .remote, customPrompt: " \nNative prompt\n ")
        settings.configuration = try DesktopConfiguration(values: [
            "postProcessingSystemPrompt": AnyCodable(.string(" \nLegacy prompt\n ")),
            "postProcessingTemperature": AnyCodable(.double(0.7))
        ])
        let before = try DataMigrationCoding.value(settings)
        let projection = try DesktopHostPreferenceArchive.project(settings, categories: categories)
        let result = try capture(settings, fields: [.customPrompt, .legacyCustomPrompt])
        let entries = Dictionary(uniqueKeysWithValues: try XCTUnwrap(result.native).entries.map { ($0.field, $0) })
        XCTAssertEqual(entries[.customPrompt]?.value, AnyCodable(.string(" \nNative prompt\n ")))
        XCTAssertEqual(entries[.legacyCustomPrompt]?.value, AnyCodable(.string(" \nLegacy prompt\n ")))
        XCTAssertEqual(entries[.customPrompt]?.sourcePath, "postProcessing.customPrompt")
        XCTAssertEqual(entries[.legacyCustomPrompt]?.sourcePath, "configuration.postProcessingSystemPrompt")
        XCTAssertEqual(result.canonical.records, projection.records)
        XCTAssertEqual(result.canonical.notices, projection.notices)
        XCTAssertEqual(try DataMigrationCoding.value(settings), before)
    }

    func testDefaultCapture_EmitsNoNativeValuesAndNamesUnselectedSources() throws {
        var settings = Settings()
        settings.postProcessing = .init(customPrompt: "fixture")
        let result = try capture(settings)
        XCTAssertEqual(result.native?.entries, [])
        XCTAssertEqual(result.native?.unresolvedPaths, [Field.customPrompt.rawValue])
        XCTAssertTrue(try capture(Settings(), fields: Field.allCases).native?.entries.allSatisfy {
            !$0.isPresent && $0.value == nil
        } == true)
    }

    func testEmptyFalseAndMissing_StayExplicitWithoutVoiceDefaults() throws {
        var settings = Settings()
        settings.postProcessing = .init(customPrompt: "")
        settings.microphoneDeviceID = ""
        settings.localUseGPU = false
        var voice = DesktopVoiceOutputSettings(modelID: "", voiceID: "future/voice")
        voice.trackUsage = false
        settings.voiceOutput = voice
        let result = try capture(settings, fields: [.customPrompt, .microphoneDeviceID, .localUseGPU,
                                                    .voiceModelID, .voiceID, .voiceTrackUsage, .legacyCustomPrompt])
        let entries = Dictionary(uniqueKeysWithValues: try XCTUnwrap(result.native).entries.map { ($0.field, $0) })
        XCTAssertEqual(entries[.customPrompt]?.value, AnyCodable(.string("")))
        XCTAssertEqual(entries[.microphoneDeviceID]?.value, AnyCodable(.string("")))
        XCTAssertEqual(entries[.localUseGPU]?.value, AnyCodable(.bool(false)))
        XCTAssertEqual(entries[.voiceModelID]?.value, AnyCodable(.string("")))
        XCTAssertEqual(entries[.voiceID]?.value, AnyCodable(.string("future/voice")))
        XCTAssertEqual(entries[.voiceTrackUsage]?.value, AnyCodable(.bool(false)))
        XCTAssertEqual(entries[.legacyCustomPrompt]?.isPresent, false)
        XCTAssertTrue(result.canonical.records.values.allSatisfy {
            !$0.contains { ["defaultTTSVoice", "ttsAutoPlay", "ttsSpeed"].contains($0.id) }
        })
    }

    func testDecodedRawShortcut_PreservesStoredMembersNotEffectiveDefaults() throws {
        let raw = AnyCodable(.object(["modifiers": .int(0), "virtualKey": .int(0), "style": .string("future")]))
        let settings = try decode(["hotKey": raw])
        let result = try capture(settings, fields: [.hotKey])
        XCTAssertEqual(result.native?.entries.first?.value, raw)
        let incomplete = try decode(["hotKey": AnyCodable(.object(["style": .string("future")]))])
        XCTAssertThrowsError(try capture(incomplete, fields: [.hotKey]))
    }

    func testUnknownNestedWrapperAndConfigurationValues_AreUnresolvedNotCaptured() throws {
        let settings = try decode([
            "futureWrapper": AnyCodable(.object(["apiKey": .string("fixture")])),
            "postProcessing": AnyCodable(.object([
                "mode": .string("remote"), "modelIdentifier": .string("fixture/model"),
                "temperature": .double(0.2), "customPrompt": .string("fixture"),
                "futureCredential": .object(["token": .string("fixture")])
            ])),
            "configuration": AnyCodable(.object([
                "unclassifiedCredential": .string("fixture")
            ]))
        ])
        let result = try capture(settings, fields: [.customPrompt])
        XCTAssertEqual(result.native?.entries.count, 1)
        XCTAssertEqual(result.unresolvedPaths, ["postProcessing.futureCredential"])
        XCTAssertTrue(result.canonical.notices.contains(.init(path: "futureWrapper", reason: .unknownPreference)))
        XCTAssertTrue(result.canonical.notices.contains(
            .init(path: "configuration.unclassifiedCredential", reason: .unknownPreference)
        ))
    }

    func testUnexpectedShortcutMembers_FailWithoutMutatingSource() throws {
        let settings = try decode(["hotKey": AnyCodable(.object([
            "modifiers": .int(0), "virtualKey": .int(0), "style": .string("future"), "token": .string("fixture")
        ]))])
        let before = try settings.nativeConfigurationSources()
        XCTAssertThrowsError(try capture(settings, fields: [.hotKey]))
        XCTAssertEqual(try settings.nativeConfigurationSources(), before)
    }

    func testExplicitWrite_ReplacesRawSourcePresenceWithoutStalePrompt() throws {
        var settings = try decode(["postProcessing": AnyCodable(.object([
            "mode": .string("remote"), "modelIdentifier": .string("fixture/model"),
            "temperature": .double(0.2), "customPrompt": .string("old")
        ]))])
        settings.postProcessing?.customPrompt = ""
        XCTAssertEqual(try capture(settings, fields: [.customPrompt]).native?.entries.first?.value,
                       AnyCodable(.string("")))
        settings.postProcessing = nil
        XCTAssertEqual(try capture(settings, fields: [.customPrompt]).native?.entries.first?.isPresent, false)
        let explicitNull = try decode(["microphoneDeviceID": AnyCodable(.null)])
        let nullEntry = try capture(explicitNull, fields: [.microphoneDeviceID]).native?.entries.first
        XCTAssertEqual(nullEntry?.isPresent, true)
        XCTAssertEqual(nullEntry?.value, AnyCodable(.null))
    }

    func testActualControllerCapture_HasNoWritesFilesOrRuntimeEffects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let effects = SettingsWriteEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        let before = await controller.settings
        let result = try await controller.configurationCapture(
            categories: categories, selectedNativeFields: [Field.customPrompt.rawValue]
        )
        let after = await controller.settings
        await controller.close()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(result.native?.entries.first?.isPresent, false)
        XCTAssertEqual(effects.writes, 0)
        XCTAssertEqual(try DataMigrationCoding.value(before), try DataMigrationCoding.value(after))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.json").path))
    }
}
