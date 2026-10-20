import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostAutomationTests: XCTestCase {
    var directory: URL!
    private var effects: SyntheticEffects!
    var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = SyntheticEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        let model = ModelCatalog.defaultBatchTranscriptionModel
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic-key", name: credential)
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    func testDefaultAndOldUnsupportedTrueAndLegacyTrue_DoNotGrantLinuxAccess() async throws {
        var enabled = await controller.automationEnabled()
        XCTAssertFalse(enabled)
        for root in [
            #"{"model":"openai/whisper-1","configuration":{"enableAutomationServer":true}}"#,
            #"{"model":"openai/whisper-1","enableAutomationServer":true}"#,
            #"{"model":"openai/whisper-1","automationEnabled":true}"#
        ] {
            try Data(root.utf8).write(to: settingsURL)
            try await restart()
            enabled = await controller.automationEnabled()
            let desired = await controller.automationDesired
            let detail = await controller.automationPreferenceDescription()
            XCTAssertFalse(enabled)
            XCTAssertTrue(desired)
            XCTAssertTrue(detail.contains("local access is off"))
        }
    }

    func testWindowsLegacyGrant_RemainsValidOnlyWithoutExplicitLocalRevocation() {
        XCTAssertTrue(DesktopAutomationConsent.allowed(
            desired: true, localGrant: nil, legacyGrant: true, requiresLocalGrant: false))
        XCTAssertFalse(DesktopAutomationConsent.allowed(
            desired: false, localGrant: nil, legacyGrant: true, requiresLocalGrant: false))
        XCTAssertFalse(DesktopAutomationConsent.allowed(
            desired: true, localGrant: false, legacyGrant: true, requiresLocalGrant: false))
        XCTAssertFalse(DesktopAutomationConsent.allowed(
            desired: true, localGrant: nil, legacyGrant: true, requiresLocalGrant: true))
    }

    func testInjectedConsent_IsNeitherImportedNorReexported() async throws {
        let configuration = try DesktopConfiguration(values: [
            "enableAutomationServer": AnyCodable(.bool(true)),
            "automationLocalConsent": AnyCodable(.bool(true))
        ])
        let file = directory.appendingPathComponent("injected-consent.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: configuration)).write(to: file)
        try await controller.importConfiguration(path: file.path)
        let enabled = await controller.automationEnabled()
        XCTAssertFalse(enabled)
        let exported = directory.appendingPathComponent("export.json")
        try await controller.exportConfiguration(path: exported.path)
        XCTAssertFalse(try String(contentsOf: exported, encoding: .utf8).contains("automationLocalConsent"))
    }

    func testExplicitGrant_RestartsButExportNeverTransfersConsent() async throws {
        try await controller.saveAutomationPreference(enabled: true)
        try await restart()
        let enabled = await controller.automationEnabled()
        XCTAssertTrue(enabled)
        let file = directory.appendingPathComponent("export.json")
        try await controller.exportConfiguration(path: file.path)
        let data = try Data(contentsOf: file)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("automationLocalConsent"))
        XCTAssertFalse(text.contains("automationEnabled"))
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: data)
        XCTAssertEqual(document.preferences.values["enableAutomationServer"], AnyCodable(.bool(true)))
    }

    func testImportTrue_PreservesIntentWithoutGrantAndFalseRevokesBeforeReturning() async throws {
        try await importPreference(true)
        var enabled = await controller.automationEnabled()
        XCTAssertFalse(enabled)
        try await controller.saveAutomationPreference(enabled: true)
        try await importPreference(true)
        enabled = await controller.automationEnabled()
        XCTAssertTrue(enabled, "An existing explicit local grant is retained")
        let revoked = expectation(description: "runtime reconciled during import")
        await controller.setAutomationPreferenceHandler { revoked.fulfill() }
        try await importPreference(false)
        await fulfillment(of: [revoked], timeout: 1)
        enabled = await controller.automationEnabled()
        XCTAssertFalse(enabled)
        try await restart()
        enabled = await controller.automationEnabled()
        XCTAssertFalse(enabled)
        try await importPreference(true)
        enabled = await controller.automationEnabled()
        XCTAssertFalse(enabled, "A false import revoked the old grant, not just its desired setting")
    }

    func testCanonicalFalse_WinsOverLegacyTrueAndInvalidImportIsRejected() async throws {
        try Data("""
        {"model":"openai/whisper-1","automationEnabled":true,
         "configuration":{"enableAutomationServer":false}}
        """.utf8).write(to: settingsURL)
        try await restart()
        let desired = await controller.automationDesired
        XCTAssertFalse(desired)
        let file = directory.appendingPathComponent("invalid.json")
        try Data(#"{"version":1,"preferences":{"enableAutomationServer":"yes"}}"#.utf8).write(to: file)
        do {
            try await controller.importConfiguration(path: file.path)
            XCTFail("Invalid automation value accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Automation"))
        }
    }

    func testFileTranscription_UsesInjectedEffectsWithoutHistoryOrOutput() async throws {
        let file = directory.appendingPathComponent("synthetic.wav")
        try Data(repeating: 0, count: 128).write(to: file)
        let result = try await controller.automationTranscribeFile(at: file)
        XCTAssertEqual(result.text, "Synthetic transcript")
        XCTAssertTrue(effects.outputs.isEmpty)
        XCTAssertTrue(FakeLog.shared.copies.isEmpty)
        let history = await controller.automationHistory(limit: 10)
        XCTAssertTrue(history.isEmpty)
        let disk = try await controller.store.recoverInterruptedRecordings()
        XCTAssertTrue(disk.records.isEmpty)
    }

    func testStatusStartStopAndHistory_ReuseSyntheticRecordingPipeline() async throws {
        var status = await controller.automationStatus()
        XCTAssertEqual(status.sessionActive, false)
        let started = try await controller.automationStartDictation()
        XCTAssertEqual(started.sessionActive, true)
        let already = await AutomationCommandDispatcher.response(
            to: .init(command: .startDictation), host: controller)
        XCTAssertEqual(already.error?.code, .alreadyRecording)
        let stopped = try await controller.automationStopDictation()
        XCTAssertEqual(stopped.text, "Synthetic transcript")
        XCTAssertEqual(stopped.sessionActive, false)
        status = await controller.automationStatus()
        XCTAssertEqual(status.sessionActive, false)
        await controller.searchHistory("does not match")
        let history = await controller.automationHistory(limit: 10)
        XCTAssertEqual(history.count, 1, "Automation reads all History, not the visible filter")
        XCTAssertEqual(history.first?.text, stopped.text)
        XCTAssertEqual(history.first?.wordCount, 2)
        XCTAssertTrue(effects.outputs.isEmpty)
        let idleStop = await AutomationCommandDispatcher.response(to: .init(command: .stopDictation), host: controller)
        XCTAssertEqual(idleStop.error?.code, .notRecording)
    }

    func testFailedSettingsWrite_DoesNotGrantAccessOrChangeDesiredPreference() async throws {
        await controller.close()
        let refusing = SettingsWriteEffects()
        refusing.refusesWrites = true
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: refusing)
        do {
            try await controller.saveAutomationPreference(enabled: true)
            XCTFail("Write failure accepted")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let enabled = await controller.automationEnabled()
        let desired = await controller.automationDesired
        XCTAssertFalse(enabled)
        XCTAssertFalse(desired)
    }

    func testFalseImport_WriteFailureStillRevokesRuntimeAndDisclosesRestartRisk() async throws {
        await controller.close()
        let refusing = SettingsWriteEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: refusing)
        try await controller.saveAutomationPreference(enabled: true)
        let revoked = expectation(description: "runtime revoked before failed write")
        await controller.setAutomationPreferenceHandler { revoked.fulfill() }
        refusing.refusesWrites = true
        do {
            try await importPreference(false)
            XCTFail("Write failure accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Restart may restore"))
        }
        await fulfillment(of: [revoked], timeout: 1)
        let enabled = await controller.automationEnabled()
        let desired = await controller.automationDesired
        XCTAssertFalse(enabled)
        XCTAssertFalse(desired)
    }

    func testFailedNativeOff_LaterReconcileAndImportsCannotRegrantThisRun() async throws {
        await controller.close()
        let refusing = SettingsWriteEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: refusing)
        try await controller.saveAutomationPreference(enabled: true)
        let app = controller!
        let runtime = Gate(open: true)
        await app.setAutomationPreferenceHandler { [weak app] in
            guard let app else { return }
            if await app.automationEnabled() { runtime.release() } else { runtime.hold() }
        }
        runtime.hold()
        refusing.refusesWrites = true
        do {
            try await app.saveAutomationPreference(enabled: false)
            XCTFail("Write failure accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("off for this run"))
            XCTAssertTrue(error.localizedDescription.contains("Restart may restore the previous local grant"))
        }
        let desired = await app.automationDesired
        let localGrant = await app.settings.automationLocalConsent
        let legacyGrant = await app.settings.automationEnabled
        XCTAssertFalse(desired)
        XCTAssertEqual(localGrant, false)
        XCTAssertNil(legacyGrant)
        let saved = try JSONDecoder().decode(
            DesktopHostController<FakePlatform>.Settings.self, from: Data(contentsOf: settingsURL)
        )
        XCTAssertEqual(saved.automationLocalConsent, true, "The restart warning reflects the unchanged saved grant")
        if await app.automationEnabled() { runtime.release() }
        XCTAssertFalse(runtime.isOpen, "A later reconcile must not restore access")
        refusing.refusesWrites = false
        try await importPreference(true)
        XCTAssertFalse(runtime.isOpen, "Imported true cannot restore the revoked local grant")
        let partial = directory.appendingPathComponent("partial.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(
            preferences: DesktopConfiguration(values: [:])
        )).write(to: partial)
        try await app.importConfiguration(path: partial.path)
        XCTAssertFalse(runtime.isOpen, "An absent automation key cannot restore the revoked local grant")
        try await restart()
        let restarted = await controller.automationEnabled()
        XCTAssertFalse(restarted, "Later successful imports persist the revoked local grant")
    }
}

extension DesktopHostAutomationTests {
    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    func restart() async throws {
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
    }

    func importPreference(_ enabled: Bool) async throws {
        let configuration = try DesktopConfiguration(values: ["enableAutomationServer": AnyCodable(.bool(enabled))])
        let document = DesktopConfigurationDocument(preferences: configuration)
        let url = directory.appendingPathComponent("import.json")
        try JSONEncoder().encode(document).write(to: url)
        try await controller.importConfiguration(path: url.path)
    }

    func testClose_CancelsSeparatelyOwnedFileCommandAndRejectsNewStarts() async throws {
        let file = directory.appendingPathComponent("synthetic.wav")
        try Data(repeating: 0, count: 128).write(to: file)
        let entered = expectation(description: "separately owned transcription entered")
        let fixture = AutomationFixtureEffects(blocking: true, onEnter: { entered.fulfill() })
        try await use(fixture)
        let app = controller!
        let command = Task { try await app.automationTranscribeFile(at: file) }
        await fulfillment(of: [entered], timeout: 1)
        let report = await app.close()
        XCTAssertTrue(report.isComplete)
        do {
            _ = try await command.value
            XCTFail("Cancelled file command succeeded")
        } catch {
            XCTAssertEqual((error as? AutomationError)?.code, .appUnavailable)
        }
        let response = await AutomationCommandDispatcher.response(to: .init(command: .startDictation), host: app)
        XCTAssertEqual(response.error?.code, .appUnavailable)
    }

    func use(_ fixture: AutomationFixtureEffects) async throws {
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: fixture)
        await controller.markReadyForSelfTest()
    }

    func importValues(_ values: [String: AnyCodable]) async throws {
        let file = directory.appendingPathComponent("preferences.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(
            preferences: DesktopConfiguration(values: values)
        )).write(to: file)
        try await controller.importConfiguration(path: file.path)
    }
}
