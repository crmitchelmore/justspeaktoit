import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostPronunciationPreferenceTests: XCTestCase {
    func testNativeEditorEvents_RequireViewIdentityAndExactPayloads() throws {
        let entries = try DesktopConfiguration(values: [:]).entries
        let id = UUID().uuidString
        for action in [Int32(0), 3, 4, 5] {
            let payload = entries + (action == 3 ? ["Recovered"] : [])
            guard case .action(let decoded, let values, let identity) =
                try DesktopHostConfigurationEditorEvent(action: action, values: payload + [id]) else {
                return XCTFail("Preference edit was decoded as a render acknowledgement.")
            }
            XCTAssertEqual(decoded, action)
            XCTAssertEqual(values, payload)
            XCTAssertEqual(identity, id)
            XCTAssertThrowsError(try DesktopHostConfigurationEditorEvent(action: action, values: payload))
        }
        guard case .rendered(let identity) = try DesktopHostConfigurationEditorEvent(action: 6, values: [id]) else {
            return XCTFail("Render acknowledgement was decoded as an edit.")
        }
        XCTAssertEqual(identity, id)
        for action in [Int32(1), 2] {
            guard case .action(let decoded, let values, let identity) =
                try DesktopHostConfigurationEditorEvent(action: action, values: ["file.json"]) else {
                return XCTFail("File action was decoded as a render acknowledgement.")
            }
            XCTAssertEqual(decoded, action)
            XCTAssertEqual(values, ["file.json"])
            XCTAssertNil(identity)
        }
        for (action, values) in [(Int32(6), [id, id]), (6, ["invalid"]), (0, entries + ["invalid"]),
                                 (0, entries + [id, id]), (3, entries + [id]), (1, ["file.json", id]),
                                 (7, ["file.json"])] {
            XCTAssertThrowsError(try DesktopHostConfigurationEditorEvent(action: action, values: values))
        }
        var invalid = entries
        invalid[try fieldIndex(ApplicationPreferenceKey.shortenErrorDisplay.rawValue)] = "true"
        XCTAssertThrowsError(try DesktopHostConfigurationEditorEvent(action: 0, values: invalid + [id]))
    }

    func testNativePresentation_ProjectsEffectiveHintsWithoutChangingPreferencesOrReadingCredentials() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        try await prepareNativeEditor(controller, root: root)
        let before = try await controller.configuration()
        let settings = root.appendingPathComponent("settings.json")
        let bytes = try Data(contentsOf: settings)
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Pronunciation presentation read a credential.") }
        let snapshot = try await controller.nativeConfigurationEditorSnapshot()
        XCTAssertEqual(snapshot.entries[try fieldIndex("assemblyAIKeyterms")], "Explicit, Modern, Legacy")
        XCTAssertEqual(snapshot.entries[try fieldIndex("transcriptionKeywords")], "Explicit")
        XCTAssertEqual(snapshot.preferences.liveOptions.keywords, ["Explicit"])
        XCTAssertEqual(snapshot.preferences.liveOptions.assemblyAIKeyterms, ["Explicit", "Legacy"])
        try await controller.activateConfigurationEditorSnapshot(snapshot)
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: settings), bytes)
        FakeLog.shared.reset()
        await controller.close()
    }

    func testUnchangedNativeProjection_ApplyAndPersistOnlyNeverPromoteSeedsAndSurviveRestart() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        try await prepareNativeEditor(controller, root: root)
        let before = try await controller.configuration()
        for intent in [DesktopConfigurationSaveIntent.apply, .persistOnly] {
            let snapshot = try await controller.nativeConfigurationEditorSnapshot()
            try await controller.activateConfigurationEditorSnapshot(snapshot)
            var entries = snapshot.entries
            entries[try fieldIndex(ApplicationPreferenceKey.shortenErrorDisplay.rawValue)] = intent == .apply ? "1" : "0"
            try await controller.saveConfiguration(entries, intent: intent)
            let after = try await controller.configuration()
            for key in ["transcriptionKeywords", "assemblyAIKeyterms",
                        ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue] {
                XCTAssertEqual(after.values[key], before.values[key], key)
            }
            XCTAssertEqual(after.liveOptions.keywords, ["Explicit"])
        }
        await controller.close()
        let restarted = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let restored = try await restarted.nativeConfigurationEditorSnapshot()
        XCTAssertEqual(restored.entries[try fieldIndex("assemblyAIKeyterms")], "Explicit, Modern, Legacy")
        XCTAssertEqual(restored.preferences.liveOptions.keywords, ["Explicit"])
        await restarted.close()
    }

    func testNativeProjectedClearAndRecoveredSelection_OnlyPersistDeliberateKeywordChoices() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        try await prepareNativeEditor(controller, root: root)
        let snapshot = try await controller.nativeConfigurationEditorSnapshot()
        try await controller.activateConfigurationEditorSnapshot(snapshot)
        var entries = snapshot.entries
        entries[try fieldIndex("assemblyAIKeyterms")] = ""
        try await controller.saveConfiguration(entries)
        let cleared = try await controller.nativeConfigurationEditorSnapshot()
        XCTAssertEqual(cleared.entries[try fieldIndex("assemblyAIKeyterms")], "")
        XCTAssertEqual(cleared.preferences.liveOptions.keywords, [])
        try await controller.activateConfigurationEditorSnapshot(cleared)
        try await controller.recoverConfigurationKeywords(cleared.entries, selected: "MODERN")
        let recovered = try await controller.nativeConfigurationEditorSnapshot()
        XCTAssertEqual(recovered.entries[try fieldIndex("assemblyAIKeyterms")], "MODERN")
        XCTAssertEqual(recovered.preferences.liveOptions.keywords, ["MODERN"])
        XCTAssertEqual(
            recovered.preferences.values[ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue],
            AnyCodable(.array([.string("hidden"), .string("legacy")]))
        )
        await controller.close()
    }

    func testNativeEditorAdmission_RefusesUnrenderedAndSupersededSnapshots() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        try await prepareNativeEditor(controller, root: root)
        let before = try await controller.configuration()
        let first = try await controller.nativeConfigurationEditorSnapshot()
        await expectSaveRefusal(first.entries, controller: controller, containing: "not ready")
        let second = try await controller.nativeConfigurationEditorSnapshot()
        do {
            try await controller.activateConfigurationEditorSnapshot(first)
            XCTFail("A superseded native editor snapshot was activated.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changed"))
        }
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
        try await controller.activateConfigurationEditorSnapshot(second)
        do {
            try await controller.saveConfiguration(second.entries, intent: .apply, editorID: first.id)
            XCTFail("A queued edit from a different view was accepted because its field values matched.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("superseded"))
        }
        try await controller.saveConfiguration(second.entries, intent: .apply, editorID: second.id)
        let saved = try await controller.configuration()
        XCTAssertEqual(saved.liveOptions.keywords, ["Explicit"])
        await controller.close()
    }

    func testNativeEditorStalePreferencesAndModel_AreRefusedWithoutOverwritingNewerSettings() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        try await prepareNativeEditor(controller, root: root)
        let original = try await controller.nativeConfigurationEditorSnapshot()
        try await controller.activateConfigurationEditorSnapshot(original)
        let transfer = root.appendingPathComponent("newer-preferences.json")
        let newer = try DesktopConfiguration(values: ["transcriptionKeywords": AnyCodable(.string("Newest"))])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: newer)).write(to: transfer)
        try await controller.importConfiguration(path: transfer.path)
        let settings = root.appendingPathComponent("settings.json")
        let bytes = try Data(contentsOf: settings)
        await expectSaveRefusal(original.entries, controller: controller, containing: "changed")
        XCTAssertEqual(try Data(contentsOf: settings), bytes)
        let fresh = try await controller.nativeConfigurationEditorSnapshot()
        try await controller.activateConfigurationEditorSnapshot(fresh)
        let other = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            DesktopHostModels.provider(for: $0.id)?.id == "openai" && !DesktopHostModels.isLive($0.id)
        })
        let selected = await controller.selectModel(other)
        XCTAssertTrue(selected)
        await expectSaveRefusal(fresh.entries, controller: controller, containing: "changed")
        let after = try await controller.configuration()
        XCTAssertEqual(after.liveOptions.keywords, ["Newest"])
        let inactive = try await controller.nativeConfigurationEditorSnapshot()
        XCTAssertEqual(inactive.entries, inactive.preferences.entries)
        await controller.close()
    }

    func testDictionaryChanges_PreserveUneditedProjectionButRefuseStaleKeywordEdits() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        try await prepareNativeEditor(controller, root: root)
        let original = try await controller.nativeConfigurationEditorSnapshot()
        try await controller.activateConfigurationEditorSnapshot(original)
        try await replaceModernWords(["Later"], controller: controller, root: root)
        var unrelated = original.entries
        unrelated[try fieldIndex(ApplicationPreferenceKey.shortenErrorDisplay.rawValue)] = "1"
        try await controller.saveConfiguration(unrelated)
        let fresh = try await controller.nativeConfigurationEditorSnapshot()
        XCTAssertEqual(fresh.entries[try fieldIndex("assemblyAIKeyterms")], "Explicit, Later, Legacy")
        XCTAssertEqual(fresh.preferences.liveOptions.keywords, ["Explicit"])
        try await controller.activateConfigurationEditorSnapshot(fresh)
        try await replaceModernWords(["Newest"], controller: controller, root: root)
        var edited = fresh.entries
        edited[try fieldIndex("assemblyAIKeyterms")] = ""
        let before = try await controller.configuration()
        await expectSaveRefusal(edited, controller: controller, containing: "Pronunciation hints changed")
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
        await controller.close()
    }

    func testRefusedProjectedClear_RetainsRuntimeDiskAndRetryableEditorAuthority() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = SettingsWriteEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        try await prepareNativeEditor(controller, root: root)
        let snapshot = try await controller.nativeConfigurationEditorSnapshot()
        try await controller.activateConfigurationEditorSnapshot(snapshot)
        let before = try await controller.configuration()
        let settings = root.appendingPathComponent("settings.json")
        let bytes = try Data(contentsOf: settings)
        var entries = snapshot.entries
        entries[try fieldIndex("assemblyAIKeyterms")] = ""
        effects.refusesWrites = true
        do {
            try await controller.saveConfiguration(entries)
            XCTFail("A refused projected clear was persisted.")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: settings), bytes)
        effects.refusesWrites = false
        try await controller.saveConfiguration(entries)
        let cleared = try await controller.nativeConfigurationEditorSnapshot()
        XCTAssertEqual(cleared.entries[try fieldIndex("assemblyAIKeyterms")], "")
        await controller.close()
    }

    private func fieldIndex(_ key: String) throws -> Int {
        try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
    }

    func testUnrenderableHintProjection_PreservesRawValuesAndReportsItsDisplayLimit() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        try await prepareNativeEditor(controller, root: root)
        for (explicit, seed) in [(String(repeating: "x", count: 65_535), "Legacy"), ("Explicit", "Bad\0Word")] {
            let configuration = try DesktopConfiguration(values: [
                "transcriptionKeywords": AnyCodable(.string(explicit)),
                ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue: AnyCodable(.object([seed: .string("spoken")]))
            ])
            let file = root.appendingPathComponent("large-native-keywords.json")
            try JSONEncoder().encode(DesktopConfigurationDocument(preferences: configuration)).write(to: file)
            try await controller.importConfiguration(path: file.path)
            let snapshot = try await controller.nativeConfigurationEditorSnapshot()
            let notice = try XCTUnwrap(snapshot.notice)
            XCTAssertEqual(snapshot.entries[try fieldIndex("assemblyAIKeyterms")], explicit)
            XCTAssertLessThanOrEqual(snapshot.entries[try fieldIndex("assemblyAIKeyterms")].utf8.count, 65_535)
            try await controller.activateConfigurationEditorSnapshot(snapshot)
            XCTAssertTrue(FakeLog.shared.allStatuses.contains(notice))
            try await controller.saveConfiguration(snapshot.entries)
            let after = try await controller.configuration()
            XCTAssertEqual(after.text("transcriptionKeywords"), explicit)
            XCTAssertEqual(
                after.values[ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue],
                configuration.values[ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue]
            )
        }
        await controller.close()
    }

    private func prepareNativeEditor(
        _ controller: DesktopHostController<FakePlatform>, root: URL
    ) async throws {
        await controller.markReadyForSelfTest()
        let initial = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("Explicit")),
            ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue:
                AnyCodable(.object(["Legacy": .string("Retained pronunciation, not a recognition hint")])),
            "recoveredTranscriptionKeywords": AnyCodable(.array([.string("MODERN")])),
            ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue: AnyCodable(.array([.string("hidden")]))
        ])
        let file = root.appendingPathComponent("native-pronunciation-preferences.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: initial)).write(to: file)
        try await controller.importConfiguration(path: file.path)
        try await replaceModernWords(["Modern", "Hidden"], controller: controller, root: root)
        let model = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == AssemblyAIModels.universal35ProBatchID })
        let selected = await controller.selectModel(model)
        XCTAssertTrue(selected)
    }

    private func replaceModernWords(
        _ words: [String], controller: DesktopHostController<FakePlatform>, root: URL
    ) async throws {
        let file = root.appendingPathComponent("native-pronunciation-words.json")
        let entries = words.map { PronunciationEntry(word: $0, pronunciation: "Not a recognition hint") }
        try JSONEncoder().encode(entries).write(to: file)
        _ = try await controller.vocabularyEvent(kind: 1, payload: DesktopVocabularyWire.encode(["importReplace", file.path]))
    }

    private func expectSaveRefusal(
        _ entries: [String], controller: DesktopHostController<FakePlatform>, containing text: String
    ) async {
        do {
            try await controller.saveConfiguration(entries)
            XCTFail("Stale or unrendered native preferences were accepted.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription)
        }
    }

    func testRootOnlyStartup_AdoptsLegacyHintsAndSuppressionWithoutCopyingValues() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dictionaryKey = ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue
        let ignoredKey = ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue
        let settings: [String: AnyCodable] = [
            "model": AnyCodable(.string(ModelCatalog.defaultBatchTranscriptionModel)),
            dictionaryKey: AnyCodable(.object(["Alpha": .string("not sent"), "Beta": .string("not sent")])),
            ignoredKey: AnyCodable(.array([.string("beta")]))
        ]
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"))
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let configuration = try await controller.configuration()
        XCTAssertEqual(configuration.liveOptions.keywords, [])
        XCTAssertEqual(configuration.liveOptions.assemblyAIKeyterms, ["Alpha"])
        XCTAssertEqual(configuration.values[dictionaryKey], settings[dictionaryKey])
        XCTAssertEqual(configuration.values[ignoredKey], settings[ignoredKey])
        await controller.close()
    }

    func testRootAndNestedStartup_ExportAndRestartPreserveNestedLegacyHints() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dictionaryKey = ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue
        let ignoredKey = ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue
        let nested = AnyCodable.JSONValue.object(["Nested": .string("retained phonetic value")])
        let settings: [String: AnyCodable] = [
            "model": AnyCodable(.string(ModelCatalog.defaultBatchTranscriptionModel)),
            dictionaryKey: AnyCodable(.object(["Root": .string("not the effective map")])),
            ignoredKey: AnyCodable(.array([.string("nested")])),
            "configuration": AnyCodable(.object([dictionaryKey: nested, ignoredKey: .array([])]))
        ]
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"))
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let effective = try await controller.configuration()
        XCTAssertEqual(effective.liveOptions.assemblyAIKeyterms, ["Nested"])
        XCTAssertEqual(effective.values[dictionaryKey], AnyCodable(nested))
        try await controller.saveConfiguration(effective.entries)
        let exported = root.appendingPathComponent("export.json")
        try await controller.exportConfiguration(path: exported.path)
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: exported))
        XCTAssertEqual(document.preferences.values[dictionaryKey], AnyCodable(nested))
        XCTAssertEqual(document.preferences.values[ignoredKey], AnyCodable(.array([])))
        await controller.close()
        let restarted = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let restored = try await restarted.configuration()
        XCTAssertEqual(restored.liveOptions.assemblyAIKeyterms, ["Nested"])
        XCTAssertEqual(restored.values[dictionaryKey], AnyCodable(nested))
        await restarted.close()
    }

    func testMalformedImportAndRefusedKeywordClear_LeaveRuntimeAndDiskUnchanged() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = SettingsWriteEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        let dictionaryKey = ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue
        let initial = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("Explicit")),
            dictionaryKey: AnyCodable(.object(["Alpha": .string("al-fa")]))
        ])
        let transfer = root.appendingPathComponent("import.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: initial)).write(to: transfer)
        try await controller.importConfiguration(path: transfer.path)
        let before = try await controller.configuration()
        let settingsFile = root.appendingPathComponent("settings.json")
        let originalBytes = try Data(contentsOf: settingsFile)
        let malformed = #"{"version":1,"preferences":{"ttsPronunciationDictionary":{"Alpha":42}}}"#
        try Data(malformed.utf8).write(to: transfer)
        do {
            try await controller.importConfiguration(path: transfer.path)
            XCTFail("A non-text legacy pronunciation was accepted.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Legacy pronunciation dictionary"))
        }
        var entries = before.entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "transcriptionKeywords" })
        entries[index] = ""
        effects.refusesWrites = true
        do {
            try await controller.saveConfiguration(entries)
            XCTFail("A refused keyword clear changed pronunciation suppression.")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: settingsFile), originalBytes)
        await controller.close()
    }
}
