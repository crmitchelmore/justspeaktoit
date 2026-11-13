import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

/// `get_configuration` and `set_configuration` on Windows and Linux (#1608).
final class DesktopHostAutomationConfigurationTests: XCTestCase {
    private typealias JSONValue = AnyCodable.JSONValue
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private let grantKey = ApplicationPreferenceKey.allowAutomationConfigurationChanges.rawValue

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-configuration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testGet_ReturnsDesktopSettingsSchemaAndKeyPresenceWithoutSecrets() async throws {
        await controller.recordTrackedAPIKey("openai.apiKey", value: "sk-secret-value")
        let result = try await controller.automationConfiguration(keys: nil, prefix: nil)
        let root = try object(result.configuration?.storage)
        XCTAssertEqual(root["platform"], .string("windows"))
        let settings = try object(root["settings"])
        XCTAssertEqual(settings["showHUD"], .bool(true))
        XCTAssertEqual(settings[grantKey], .bool(false))
        XCTAssertEqual(settings["autoCorrectionsPromotionThreshold"].map(isInteger), true)
        XCTAssertTrue(Set(settings.keys).isSubset(of: SettingsSchema.keys(for: .windows)))
        XCTAssertEqual(try object(root["apiKeys"])["openai.apiKey"], .object(["isSet": .bool(true)]))
        let schema = try object(root["schema"])
        XCTAssertEqual(try object(schema[grantKey])["readOnly"], .bool(true))
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(result), encoding: .utf8))
        XCTAssertFalse(encoded.contains("sk-secret-value"))
    }

    func testSet_RefusesWritesUntilGrantedButAlwaysAllowsDryRun() async throws {
        do {
            _ = try await controller.automationSetConfiguration(["showHUD": .bool(false)], dryRun: false)
            XCTFail("A write without the local grant must fail")
        } catch let error as AutomationError {
            XCTAssertEqual(error.code, .unsupportedCommand)
            XCTAssertTrue(error.message.contains("Preferences → General"))
        }
        let dryRun = try await controller.automationSetConfiguration(["showHUD": .bool(false)], dryRun: true)
        XCTAssertEqual(try object(dryRun.configuration?.storage)["applied"], .bool(false))
        let showHUD = try await setting("showHUD")
        XCTAssertEqual(showHUD, .bool(true))
    }

    func testSet_AppliesValidChangesThroughThePreferencesSavePath() async throws {
        try await grantWrites()
        let result = try await controller.automationSetConfiguration(
            ["showHUD": .bool(false), "holdThreshold": .double(0.5)], dryRun: false
        )
        XCTAssertEqual(try object(result.configuration?.storage)["applied"], .bool(true))
        let showHUD = try await setting("showHUD")
        let holdThreshold = try await setting("holdThreshold")
        let configuration = try await controller.configuration()
        XCTAssertEqual(showHUD, .bool(false))
        XCTAssertEqual(holdThreshold, .double(0.5))
        XCTAssertEqual(configuration.enabled("showHUD"), false)
    }

    func testSet_IsAllOrNothingAndNeverChangesTheGrantOrUnknownKeys() async throws {
        try await grantWrites()
        for changes: [String: JSONValue] in [
            ["showHUD": .bool(false), "holdThreshold": .double(9)],
            ["showHUD": .bool(false), grantKey: .bool(false)],
            ["showHUD": .bool(false), "noSuchSetting": .bool(true)]
        ] {
            do {
                _ = try await controller.automationSetConfiguration(changes, dryRun: false)
                XCTFail("Expected \(changes) to be refused")
            } catch let error as AutomationError {
                XCTAssertEqual(error.code, .invalidArgument)
            }
            let showHUD = try await setting("showHUD")
            let grant = try await setting(grantKey)
            XCTAssertEqual(showHUD, .bool(true))
            XCTAssertEqual(grant, .bool(true))
        }
    }

    func testImport_KeepsThisComputersAutomationWriteGrant() async throws {
        let file = directory.appendingPathComponent("granting.json")
        let preferences = try DesktopConfiguration(values: [grantKey: AnyCodable(.bool(true))])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences)).write(to: file)
        try await controller.importConfiguration(path: file.path)
        let grant = try await setting(grantKey)
        XCTAssertEqual(grant, .bool(false))
    }

    private func grantWrites() async throws {
        let granted = try await controller.configuration().values.merging(
            [grantKey: AnyCodable(.bool(true))]) { _, new in new }
        try await controller.persistConfiguration(
            DesktopConfiguration(values: granted), intent: .persistOnly, status: "Granted."
        )
    }

    private func setting(_ key: String) async throws -> JSONValue? {
        let result = try await controller.automationConfiguration(keys: [key], prefix: nil)
        return try object(object(result.configuration?.storage)["settings"])[key]
    }

    private func object(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard case .object(let object)? = value else {
            XCTFail("Expected an object, got \(String(describing: value))")
            return [:]
        }
        return object
    }

    private func isInteger(_ value: JSONValue) -> Bool {
        if case .int = value { return true }
        return false
    }
}
