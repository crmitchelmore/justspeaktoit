import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostLocalModelTransferTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private let batch = "local/whisperkit/tiny"
    private let live = "local/streaming/whisperkit/tiny"
    private let batchKey = ApplicationPreferenceKey.localTranscriptionModel.rawValue
    private let liveKey = ApplicationPreferenceKey.localStreamingModelSource.rawValue

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(
            streamingQualified: true, local: DesktopLocalTranscription.options(host: .linux),
            localLive: DesktopLocalStreaming.options(host: .linux)
        )
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true, local: [], localLive: [])
    }

    private func document(_ values: [String: AnyCodable]) throws -> URL {
        let file = directory.appendingPathComponent("import.json")
        let configuration = try DesktopConfiguration(values: values)
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: configuration)).write(to: file)
        return file
    }

    private func exported() async throws -> DesktopConfiguration {
        let file = directory.appendingPathComponent("export.json")
        try await controller.exportConfiguration(path: file.path)
        return try JSONDecoder().decode(
            DesktopConfigurationDocument.self, from: Data(contentsOf: file)
        ).preferences
    }

    private func select(_ identifier: String) async throws {
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == identifier })
        let accepted = await controller.selectModel(index)
        XCTAssertTrue(accepted)
    }

    func testSupportedChoices_SaveRestartExportWithoutActivationOrCredentials() async throws {
        let remoteLive = try XCTUnwrap(DesktopHostModels.live.last?.id)
        try await select(remoteLive)
        let remoteBatch = ModelCatalog.defaultBatchTranscriptionModel
        try await select(remoteBatch)
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Local model import accessed a credential") }
        let file = try document([batchKey: AnyCodable(.string(batch)), liveKey: AnyCodable(.string(live))])
        try await controller.importConfiguration(path: file.path)
        let saved = await controller.settings
        XCTAssertEqual(saved.model, remoteBatch)
        XCTAssertEqual(saved.batchModel, remoteBatch)
        XCTAssertEqual(saved.liveModel, remoteLive)
        XCTAssertEqual(saved.localModel, batch)
        XCTAssertEqual(saved.localLiveModel, live)
        XCTAssertNil(saved.configuration?.values[batchKey])
        XCTAssertNil(saved.configuration?.values[liveKey])
        XCTAssertEqual(FakeLog.shared.publishedLocalChoices.last?.local, batch)
        XCTAssertEqual(FakeLog.shared.publishedLocalChoices.last?.localLive, live)
        var entries = try await controller.configuration().entries
        entries[try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "preferredLocale" })] = "fr_FR"
        try await controller.saveConfiguration(entries)
        let withoutMirrors = await controller.settings
        XCTAssertNil(withoutMirrors.configuration?.values[liveKey])
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restored = await controller.preferredModelIDs()
        XCTAssertEqual(restored.batch, remoteBatch)
        XCTAssertEqual(restored.live, remoteLive)
        XCTAssertEqual(restored.local, batch)
        XCTAssertEqual(restored.localLive, live)
        let values = try await exported().values
        XCTAssertEqual(values[batchKey], AnyCodable(.string(batch)))
        XCTAssertEqual(values[liveKey], AnyCodable(.string(live)))
    }

    func testUnsupportedAndWrongModeIDs_RoundTripWithoutFallback() async throws {
        let values = [
            batchKey: AnyCodable(.string(live)),
            liveKey: AnyCodable(.string("local/streaming/huggingface/future/model"))
        ]
        try await controller.importConfiguration(path: document(values).path)
        let saved = await controller.settings
        XCTAssertNil(saved.localModel)
        XCTAssertNil(saved.localLiveModel)
        XCTAssertTrue(FakeLog.shared.publishedLocalChoices.isEmpty)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Preserved but not applied") == true)
        let result = try await exported()
        for (key, value) in values { XCTAssertEqual(result.values[key], value) }
    }

    func testActiveLiveChoice_IsPreservedUntilExplicitModelSelection() async throws {
        try await select(live)
        let other = try XCTUnwrap(DesktopHostModels.localLive.last { $0.id != live }?.id)
        let file = try document([
            liveKey: AnyCodable(.string(other)), "localTranscriptionMode": AnyCodable(.string("batch"))
        ])
        try await controller.importConfiguration(path: file.path)
        let retained = await controller.settings
        XCTAssertEqual(retained.model, live)
        XCTAssertEqual(retained.localLiveModel, live)
        XCTAssertEqual(retained.configuration?.values[liveKey], AnyCodable(.string(other)))
        XCTAssertTrue(FakeLog.shared.publishedLocalChoices.isEmpty)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("changes to the active mode") == true)
        let pending = try await exported()
        XCTAssertEqual(pending.values[liveKey], AnyCodable(.string(other)))
        XCTAssertEqual(pending.values["localTranscriptionMode"], AnyCodable(.string("batch")))
        try await select(live)
        let selected = await controller.settings
        XCTAssertNil(selected.configuration?.values[liveKey])
        let result = try await exported()
        XCTAssertEqual(result.values[liveKey], AnyCodable(.string(live)))
        XCTAssertEqual(result.values["localTranscriptionMode"], AnyCodable(.string("streaming")))
        try await select(batch)
        let batchResult = try await exported()
        XCTAssertEqual(batchResult.values["localTranscriptionMode"], AnyCodable(.string("batch")))
    }

    func testInvalidTypes_RejectTheWholeImportBeforePersistenceOrPublication() async throws {
        let before = await controller.settings
        for value in [AnyCodable(.bool(true)), AnyCodable(.array([.string(live)])), AnyCodable(.int(1))] {
            let file = try document([batchKey: AnyCodable(.string(batch)), liveKey: value])
            do { try await controller.importConfiguration(path: file.path); XCTFail("Invalid model choice accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Local model choice")) }
            let after = await controller.settings
            XCTAssertEqual(after.model, before.model)
            XCTAssertEqual(after.localModel, before.localModel)
            XCTAssertEqual(after.localLiveModel, before.localLiveModel)
            XCTAssertEqual(after.configuration, before.configuration)
            XCTAssertTrue(FakeLog.shared.publishedLocalChoices.isEmpty)
        }
    }

    func testFailedSettingsWrite_DoesNotChangeSlotsOrPublish() async throws {
        await controller.close()
        let effects = SettingsWriteEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        let configuration = try await controller.configuration()
        try await controller.saveConfiguration(configuration.entries)
        let file = directory.appendingPathComponent("settings.json")
        let before = try Data(contentsOf: file)
        effects.refusesWrites = true
        let source = try document([liveKey: AnyCodable(.string(live))])
        do { try await controller.importConfiguration(path: source.path); XCTFail("Failed write accepted") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue) }
        let saved = await controller.settings
        XCTAssertNil(saved.localLiveModel)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(FakeLog.shared.publishedLocalChoices.isEmpty)
    }

    func testFailedNativePublication_ReportsSavedStateAndSurvivesRestart() async throws {
        FakeLog.shared.refuseLocalChoices(true)
        let source = try document([liveKey: AnyCodable(.string(live))])
        do { try await controller.importConfiguration(path: source.path); XCTFail("Publication failure ignored") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Configuration saved"))
            XCTAssertTrue(error.localizedDescription.contains("Reopen the app"))
        }
        await controller.close()
        FakeLog.shared.refuseLocalChoices(false)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restored = await controller.settings
        XCTAssertEqual(restored.localLiveModel, live)
        XCTAssertFalse(DesktopHostModels.isLocal(restored.model))
    }

    func testAbsentKeys_KeepChoicesAndDoNotRepublish() async throws {
        try await controller.importConfiguration(path: document([liveKey: AnyCodable(.string(live))]).path)
        let count = FakeLog.shared.publishedLocalChoices.count
        let unrelated = try document(["preferredLocale": AnyCodable(.string("de_DE"))])
        try await controller.importConfiguration(path: unrelated.path)
        let restored = await controller.settings
        XCTAssertEqual(restored.localLiveModel, live)
        XCTAssertEqual(FakeLog.shared.publishedLocalChoices.count, count)
    }
}

extension DesktopHostPreferenceArchiveTests {
    func testLocalLiveArchive_UsesStreamingKeyAndExplicitPresence() throws {
        typealias Settings = DesktopHostController<FakePlatform>.Settings
        let live = "local/streaming/whisperkit/tiny"
        var settings = Settings()
        settings.localLiveModel = live
        let encoded = try JSONEncoder().encode(settings)
        settings = try JSONDecoder().decode(Settings.self, from: encoded)
        var result = try DesktopHostPreferenceArchive.project(settings, categories: [.settings])
        var values = Dictionary(uniqueKeysWithValues: result.records.values.flatMap { $0 }.map { ($0.id, $0.value) })
        XCTAssertEqual(values["localStreamingModelSource"], AnyCodable(.string(live)))
        XCTAssertNil(values["localTranscriptionModel"])
        XCTAssertNil(values["localTranscriptionMode"])
        settings.model = live
        result = try DesktopHostPreferenceArchive.project(settings, categories: [.settings])
        values = Dictionary(uniqueKeysWithValues: result.records.values.flatMap { $0 }.map { ($0.id, $0.value) })
        XCTAssertEqual(values["transcriptionMode"], AnyCodable(.string("localModel")))
        XCTAssertEqual(values["localTranscriptionMode"], AnyCodable(.string("streaming")))
        XCTAssertEqual(values["localStreamingModelSource"], AnyCodable(.string(live)))
        XCTAssertNil(values["localTranscriptionModel"])
    }
}
