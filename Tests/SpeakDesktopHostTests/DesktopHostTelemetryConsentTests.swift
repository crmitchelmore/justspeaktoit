import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

/// Telemetry consent moves only through an explicit native Settings change:
/// never from an import, a stored file or an automation write.
final class DesktopHostTelemetryConsentTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SettingsWriteEffects())
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func editorEntries(analytics: Bool, diagnostics: Bool) async throws -> [String] {
        var entries = try await controller.configurationForNativeEditor().entries
        for (key, value) in [
            DesktopTelemetryConsent.analyticsKey: analytics, DesktopTelemetryConsent.diagnosticsKey: diagnostics
        ] {
            let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
            entries[index] = value ? "1" : "0"
        }
        return entries
    }

    private func assertUndecided(file: StaticString = #filePath, line: UInt = #line) async throws {
        let state = controller.telemetry.store.snapshot()
        XCTAssertEqual(state.analyticsConsent, .unknown, file: file, line: line)
        XCTAssertEqual(state.diagnosticsConsent, .undecided, file: file, line: line)
        let editor = try await controller.configurationForNativeEditor()
        XCTAssertFalse(editor.enabled(DesktopTelemetryConsent.analyticsKey), file: file, line: line)
        XCTAssertFalse(editor.enabled(DesktopTelemetryConsent.diagnosticsKey), file: file, line: line)
    }

    private func storedSettings() throws -> String {
        let data = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
        return try XCTUnwrap(String(bytes: data, encoding: .utf8))
    }

    func testImport_NeverGrantsConsent() async throws {
        let path = directory.appendingPathComponent("import.json").path
        let preferences = try DesktopConfiguration(values: [
            DesktopTelemetryConsent.analyticsKey: AnyCodable(.bool(true)),
            DesktopTelemetryConsent.diagnosticsKey: AnyCodable(.bool(true)),
            "analyticsEnabled": AnyCodable(.bool(true)),
            "analyticsConsent": AnyCodable(.string("optedIn")),
            "diagnosticsConsent": AnyCodable(.string("granted"))
        ])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences))
            .write(to: URL(fileURLWithPath: path))
        try await controller.importConfiguration(path: path)

        try await assertUndecided()
        let stored = try storedSettings()
        XCTAssertFalse(stored.contains(DesktopTelemetryConsent.analyticsKey))
        XCTAssertFalse(stored.contains(DesktopTelemetryConsent.diagnosticsKey))

        let export = directory.appendingPathComponent("export.json").path
        try await controller.saveConfiguration(try await editorEntries(analytics: true, diagnostics: true))
        try await controller.exportConfiguration(path: export)
        let exported = try XCTUnwrap(String(bytes: Data(contentsOf: URL(fileURLWithPath: export)), encoding: .utf8))
        XCTAssertFalse(exported.contains(DesktopTelemetryConsent.analyticsKey))
        XCTAssertFalse(exported.contains(DesktopTelemetryConsent.diagnosticsKey))
    }

    func testAutomationAndPreviewWrites_NeverGrantConsent() async throws {
        var values = try await controller.configuration().values
        values[DesktopTelemetryConsent.analyticsKey] = AnyCodable(.bool(true))
        values[DesktopTelemetryConsent.diagnosticsKey] = AnyCodable(.bool(true))
        try await controller.persistConfiguration(
            DesktopConfiguration(values: values), intent: .apply, status: "Automation write."
        )
        try await assertUndecided()

        try await controller.saveConfiguration(
            try await editorEntries(analytics: true, diagnostics: true), intent: .persistOnly
        )
        try await assertUndecided()
        XCTAssertFalse(try storedSettings().contains(DesktopTelemetryConsent.analyticsKey))
    }

    func testSettingsApply_SetsEachConsentSeparately() async throws {
        try await controller.saveConfiguration(try await editorEntries(analytics: false, diagnostics: false))
        try await assertUndecided()

        try await controller.saveConfiguration(try await editorEntries(analytics: false, diagnostics: true))
        var state = controller.telemetry.store.snapshot()
        XCTAssertEqual(state.analyticsConsent, .unknown)
        XCTAssertEqual(state.diagnosticsConsent, .granted)

        try await controller.saveConfiguration(try await editorEntries(analytics: true, diagnostics: true))
        state = controller.telemetry.store.snapshot()
        XCTAssertEqual(state.analyticsConsent, .optedIn)
        let editor = try await controller.configurationForNativeEditor()
        XCTAssertTrue(editor.enabled(DesktopTelemetryConsent.analyticsKey))

        try await controller.saveConfiguration(try await editorEntries(analytics: false, diagnostics: false))
        state = controller.telemetry.store.snapshot()
        XCTAssertEqual(state.analyticsConsent, .optedOut)
        XCTAssertEqual(state.diagnosticsConsent, .declined)
        XCTAssertNil(state.installationID)
        XCTAssertFalse(try storedSettings().contains(DesktopTelemetryConsent.analyticsKey))
    }
}
