import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

/// Preferences › General › Edit raw configuration on Windows and Linux (#1670).
final class DesktopHostRawConfigurationTests: XCTestCase {
    private typealias JSONValue = AnyCodable.JSONValue
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private let grantKey = ApplicationPreferenceKey.allowAutomationConfigurationChanges.rawValue

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-configuration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testLoad_ShowsTheSharedDocumentWithoutSecrets() async throws {
        await controller.recordTrackedAPIKey("openai.apiKey", value: "sk-secret-value")
        let outcome = await controller.rawConfiguration(.load, text: "")
        let text = try XCTUnwrap(outcome.text)
        XCTAssertFalse(outcome.failed)
        XCTAssertFalse(text.contains("sk-secret-value"))
        let document = try SettingsDocument.parse(Data(text.utf8)).get()
        XCTAssertEqual(document.settings["showHUD"], .bool(true))
        XCTAssertEqual(document.apiKeys["openai.apiKey"], true)
    }

    func testApply_SavesValidChangesWithoutTheAutomationGrant() async throws {
        let outcome = await controller.rawConfiguration(.apply, text: try await edited(["showHUD": .bool(false)]))
        XCTAssertFalse(outcome.failed, outcome.issuesText)
        XCTAssertEqual(outcome.status, "Saved 1 change(s).")
        XCTAssertTrue(try XCTUnwrap(outcome.text).contains("\"showHUD\" : false"))
        let configuration = try await controller.configuration()
        XCTAssertEqual(configuration.enabled("showHUD"), false)
    }

    func testApply_InvalidDocumentSavesNothingAndKeepsTheUsersText() async throws {
        for text in [try await edited(["showHUD": .bool(false), "holdThreshold": .double(9)]), "{ not json"] {
            let outcome = await controller.rawConfiguration(.apply, text: text)
            XCTAssertTrue(outcome.failed)
            XCTAssertNil(outcome.text)
            XCTAssertTrue(outcome.status.hasPrefix("The configuration is not valid."))
            XCTAssertTrue(outcome.announcement.contains(outcome.errors[0]))
            let configuration = try await controller.configuration()
            XCTAssertEqual(configuration.enabled("showHUD"), true)
        }
    }

    func testApply_KeepsReadOnlyGrantWithAWarning() async throws {
        let outcome = await controller.rawConfiguration(
            .apply, text: try await edited(["showHUD": .bool(false), grantKey: .bool(true)])
        )
        XCTAssertFalse(outcome.failed, outcome.issuesText)
        XCTAssertFalse(outcome.warnings.isEmpty)
        XCTAssertTrue(outcome.issuesText.hasPrefix("Warning: "))
        let configuration = try await controller.configuration()
        XCTAssertEqual(configuration.enabled("showHUD"), false)
        XCTAssertEqual(configuration.enabled(grantKey), false)
    }

    func testValidateAndDefaults_DoNotSave() async throws {
        let validate = await controller.rawConfiguration(.validate, text: try await edited(["showHUD": .bool(false)]))
        XCTAssertEqual(validate.status, "Valid. 1 change(s) ready.")
        XCTAssertNil(validate.text)
        _ = await controller.rawConfiguration(.apply, text: try await edited(["showHUD": .bool(false)]))
        let defaults = await controller.rawConfiguration(.defaults, text: "")
        XCTAssertEqual(defaults.status, "Defaults loaded. Apply to save them.")
        let document = try SettingsDocument.parse(Data(try XCTUnwrap(defaults.text).utf8)).get()
        XCTAssertEqual(document.settings["showHUD"], .bool(true))
        let configuration = try await controller.configuration()
        XCTAssertEqual(configuration.enabled("showHUD"), false)
    }

    func testImport_FillsTheEditorAndValidatesWithoutSaving() async throws {
        let file = directory.appendingPathComponent("import.json")
        let text = try await edited(["showHUD": .bool(false)])
        try Data(text.utf8).write(to: file)
        let outcome = await controller.rawConfiguration(.importFile, text: file.path)
        XCTAssertEqual(outcome.text, text)
        XCTAssertEqual(outcome.status, "Valid. 1 change(s) ready.")
        let configuration = try await controller.configuration()
        XCTAssertEqual(configuration.enabled("showHUD"), true)

        let large = directory.appendingPathComponent("large.json")
        try Data(count: DesktopHostController<FakePlatform>.rawConfigurationMaximumBytes + 1).write(to: large)
        for path in [large.path, directory.appendingPathComponent("missing.json").path] {
            let refused = await controller.rawConfiguration(.importFile, text: path)
            XCTAssertTrue(refused.failed)
            XCTAssertNil(refused.text)
        }
    }

    func testExport_WritesTheNormalisedDocumentAndRefusesInvalidOrPathlessPayloads() async throws {
        let file = directory.appendingPathComponent("export.json")
        let text = try await edited(["showHUD": .bool(false)])
        let outcome = await controller.rawConfiguration(.export, text: "\(file.path)\n\(text)")
        XCTAssertFalse(outcome.failed, outcome.issuesText)
        XCTAssertEqual(outcome.status, "Exported to export.json.")
        let written = try SettingsDocument.parse(Data(contentsOf: file)).get()
        XCTAssertEqual(written.settings["showHUD"], .bool(false))

        let other = directory.appendingPathComponent("bad.json")
        for payload in ["\(other.path)\n{ not json", "\n\(text)", text] {
            let refused = await controller.rawConfiguration(.export, text: payload)
            XCTAssertTrue(refused.failed, payload)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    private func edited(_ changes: [String: JSONValue]) async throws -> String {
        let loaded = await controller.rawConfiguration(.load, text: "")
        var document = try SettingsDocument.parse(Data(try XCTUnwrap(loaded.text).utf8)).get()
        for (key, value) in changes { document.settings[key] = value }
        return String(decoding: try document.encodedJSON(), as: UTF8.self)
    }
}
