import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostAppSwitchDeliveryTests: XCTestCase {
    private var directory: URL!
    private var effects: AppSwitchEffects!
    private var host: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("app-switch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = AppSwitchEffects()
        host = try DesktopHostController(directory: directory, effects: effects)
    }

    override func tearDown() async throws {
        await host.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func apply(_ policy: AppSwitchDelivery?) async throws {
        let editor = try await host.configurationForNativeEditor()
        var values = editor.values
        values[AppSwitchDelivery.preferenceKey] = AnyCodable(.string(policy?.rawValue ?? ""))
        try await host.saveConfiguration(DesktopConfiguration(values: values).entries)
    }

    func testNativeEditorExportAndRestartKeepOnePersistedPolicyOwner() async throws {
        let key = AppSwitchDelivery.preferenceKey
        for policy in AppSwitchDelivery.allCases {
            try await apply(policy)
            let stored = await host.settings
            XCTAssertEqual(stored.textOutput?.appSwitchDelivery, policy)
            XCTAssertNil(stored.configuration?.values[key])
            let editor = try await host.configurationForNativeEditor()
            XCTAssertEqual(editor.values[key], AnyCodable(.string(policy.rawValue)))
            let file = directory.appendingPathComponent("export.json")
            try await host.exportConfiguration(path: file.path)
            let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: file))
            XCTAssertEqual(document.preferences.values[key], AnyCodable(.string(policy.rawValue)))
            await host.close()
            host = try DesktopHostController(directory: directory, effects: effects)
            let restarted = await host.settings
            XCTAssertEqual(restarted.textOutput?.appSwitchDelivery, policy)
            XCTAssertNil(restarted.configuration?.values[key])
        }
    }

    func testPartialImportPreservesPolicyAndUnknownMacValues() async throws {
        try await apply(.currentApp)
        let source = try DesktopConfiguration(values: ["future-mac-field": AnyCodable(.string("retain"))])
        let file = directory.appendingPathComponent("partial.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: source)).write(to: file)
        try await host.importConfiguration(path: file.path)
        let stored = await host.settings
        XCTAssertEqual(stored.textOutput?.appSwitchDelivery, .currentApp)
        XCTAssertEqual(stored.configuration?.values["future-mac-field"], AnyCodable(.string("retain")))
        try await apply(.onlyIfOriginalAppInFront)
        let afterEditor = await host.settings
        XCTAssertEqual(afterEditor.configuration?.values["future-mac-field"], AnyCodable(.string("retain")))
    }

    func testImportedPolicyMovesFromDocumentToNativeOptionsAndSurvivesRestart() async throws {
        let key = AppSwitchDelivery.preferenceKey
        let source = try DesktopConfiguration(values: [key: AnyCodable(.string("onlyIfOriginalAppInFront"))])
        let file = directory.appendingPathComponent("import.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: source)).write(to: file)
        try await host.importConfiguration(path: file.path)
        await host.close()
        host = try DesktopHostController(directory: directory, effects: effects)
        let stored = await host.settings
        XCTAssertEqual(stored.textOutput?.appSwitchDelivery, .onlyIfOriginalAppInFront)
        XCTAssertNil(stored.configuration?.values[key])
    }

    func testAbsentKeyStaysLegacyAndRetainedPrePolicyMirrorMigratesAtStartup() async throws {
        let key = AppSwitchDelivery.preferenceKey
        let editor = try await host.configurationForNativeEditor()
        let runtime = try await host.configuration()
        XCTAssertEqual(editor.values[key], AnyCodable(.string("")))
        XCTAssertNil(runtime.values[key])
        var legacy = await host.settings
        legacy.textOutput = nil
        legacy.configuration = try DesktopConfiguration(values: [key: AnyCodable(.string("originalApp"))])
        await host.close()
        try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent("settings.json"))
        host = try DesktopHostController(directory: directory, effects: effects)
        let migrated = await host.settings
        XCTAssertEqual(migrated.textOutput?.appSwitchDelivery, .originalApp)
        XCTAssertNil(migrated.configuration?.values[key])
    }

    func testFailedAtomicWriteDoesNotPublishNewPolicyOrChangeSavedBytes() async throws {
        try await apply(.originalApp)
        let file = directory.appendingPathComponent("settings.json")
        let before = try Data(contentsOf: file)
        effects.rejectWrites = true
        do {
            try await apply(.currentApp)
            XCTFail("Expected the synthetic write failure")
        } catch { XCTAssertTrue(error is CocoaError) }
        let stored = await host.settings
        XCTAssertEqual(stored.textOutput?.appSwitchDelivery, .originalApp)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testClosedControllerCannotPublishPolicy() async throws {
        try await apply(.originalApp)
        await host.close()
        do {
            try await apply(.currentApp)
            XCTFail("Closed configuration save must be rejected")
        } catch {}
        let stored = await host.settings
        XCTAssertEqual(stored.textOutput?.appSwitchDelivery, .originalApp)
    }

    func testRecordingEventKeepsCapturedPolicyAfterLaterSettingChange() async throws {
        try await apply(.originalApp)
        let event = await host.captureRecordingEvent(modelIndex: nil, executablePath: nil)
        try await apply(.currentApp)
        let later = await host.captureRecordingEvent(modelIndex: nil, executablePath: nil)
        XCTAssertEqual(event.textOutput.appSwitchDelivery, .originalApp)
        XCTAssertEqual(later.textOutput.appSwitchDelivery, .currentApp)
    }
}

private final class AppSwitchEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    private let underlying = SyntheticEffects()
    var rejectWrites = false
    func apiKey(name: String) throws -> String { try underlying.apiKey(name: name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        try underlying.makeCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult { try await underlying.transcribe(request, with: controller) }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { underlying.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws {
        if rejectWrites { throw CocoaError(.fileWriteUnknown) }
        try underlying.writeSettings(data, to: url)
    }
}
