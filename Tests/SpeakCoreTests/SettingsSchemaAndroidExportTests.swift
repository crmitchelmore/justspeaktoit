import Foundation
import XCTest

@testable import SpeakCore

/// The Android app validates raw configurations against a committed JSON asset;
/// this keeps it identical to `SettingsSchema.fields(for: .android)`.
final class SettingsSchemaAndroidExportTests: XCTestCase {
    private var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets/settings_schema.json")
    }

    func testAndroidAssetMatchesSchema() throws {
        let expected = try SettingsSchemaAndroidExport.json()
        if ProcessInfo.processInfo.environment["UPDATE_SETTINGS_SCHEMA_ANDROID"] == "1" {
            try expected.write(to: assetURL)
        }
        let committed = try Data(contentsOf: assetURL)
        XCTAssertEqual(
            committed, expected,
            "android/app/src/main/assets/settings_schema.json is stale. Regenerate with scripts/update-android-assets"
        )
    }

    func testAndroidSchema_defaultsPassAndEveryKeyIsSearchableOnAndroid() throws {
        let fields = SettingsSchema.fields(for: .android)
        XCTAssertFalse(fields.isEmpty)
        XCTAssertFalse(fields.contains(where: \.isSensitive))
        let defaults = fields.reduce(into: [String: AnyCodable.JSONValue]()) { $0[$1.key] = $1.defaultValue }
        var context = SettingsValidationContext(currentValues: [:])
        context.platform = .android
        let report = SettingsValidator.validate(settings: defaults, context: context)
        XCTAssertEqual(report.errors, [])
        for field in fields where !["chosen_mode", "history_retention"].contains(field.key) {
            XCTAssertTrue(
                SettingsSearchCatalog.entries(for: .android).contains { $0.settingKeys.contains(field.key) },
                "\(field.key) has no Android settings search entry")
        }
    }

    func testAndroidSchema_rejectsModelsAndroidDoesNotOffer() {
        var context = SettingsValidationContext(currentValues: [:])
        context.platform = .android
        let report = SettingsValidator.validate(
            settings: ["cloud_model": .string("deepgram/nova-3"), "postProcessingEnabled": .bool(true)],
            context: context)
        XCTAssertEqual(report.errors.map(\.path), ["settings.cloud_model"])
        XCTAssertEqual(report.ignoredKeys, ["postProcessingEnabled"])
    }
}
