import XCTest
@testable import SpeakCore

/// The shared raw-configuration schema, document format and validator (#1546).
final class SettingsConfigurationTests: XCTestCase {
    private typealias JSONValue = AnyCodable.JSONValue

    /// Every field's default, as the current value, so read-only fields are satisfied.
    private var defaults: [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: SettingsSchema.fields.compactMap { field in
            field.defaultValue.map { (field.key, $0) }
        })
    }

    private func validate(
        _ settings: [String: JSONValue], current: [String: JSONValue]? = nil
    ) -> SettingsValidationReport {
        SettingsValidator.validate(
            settings: settings, context: SettingsValidationContext(currentValues: current ?? self.defaults)
        )
    }

    private func errorPaths(_ report: SettingsValidationReport) -> [String] {
        report.errors.map(\.path)
    }

    // MARK: - Schema

    func testSchema_keysAreUniqueAndDefaultsSatisfyTheirOwnRules() {
        XCTAssertEqual(Set(SettingsSchema.keys).count, SettingsSchema.keys.count)
        let report = self.validate(self.defaults)
        XCTAssertEqual(report.errors, [], "A schema default must pass the schema")
        XCTAssertEqual(report.changes, [:])
    }

    func testSchema_describesTypeDefaultRangeAndPlatforms() throws {
        let description = SettingsSchema.describe(keys: ["ttsSpeed"])
        guard case .object(let speed)? = description["ttsSpeed"] else { return XCTFail("ttsSpeed missing") }
        XCTAssertEqual(speed["type"], .string("number"))
        XCTAssertEqual(speed["default"], .double(1))
        XCTAssertEqual(speed["minimum"], .double(0.5))
        XCTAssertEqual(speed["maximum"], .double(2))
        XCTAssertNotNil(speed["platforms"])
        XCTAssertNotNil(speed["description"])
    }

    func testSchema_hasNoSensitiveFields() {
        XCTAssertEqual(SettingsSchema.fields.filter(\.isSensitive).map(\.key), [],
                       "Secrets stay in the Keychain; documents carry only apiKeys.isSet")
    }

    // MARK: - Document

    func testDocument_roundTripsWithoutLossIncludingForeignKeys() throws {
        let document = SettingsDocument(
            settings: [
                "ttsSpeed": .double(1.25), "showHUDDuringSessions": .bool(false),
                "ttsFavoriteVoices": .array([.string("a/b")]), "iosOnlySetting": .string("kept")
            ],
            apiKeys: ["openai": true, "deepgram": false]
        )
        let parsed = try SettingsDocument.parse(document.encodedJSON()).get()
        XCTAssertEqual(parsed, document)
    }

    func testDocument_reportsEveryStructuralProblemWithItsPath() {
        let json = #"{"schemaVersion": 99, "extra": 1, "settings": [], "apiKeys": {"openai": "sk-secret"}}"#
        guard case .failure(let error) = SettingsDocument.parse(Data(json.utf8)) else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(Set(error.issues.map(\.path)), ["extra", "schemaVersion", "settings", "apiKeys.openai"])
    }

    func testDocument_rejectsInvalidJSONAndMissingVersion() {
        guard case .failure(let invalid) = SettingsDocument.parse(Data("{".utf8)),
              case .failure(let missing) = SettingsDocument.parse(Data("{}".utf8)) else {
            return XCTFail("Expected failures")
        }
        XCTAssertTrue(invalid.issues.first?.message.hasPrefix("Not valid JSON") == true)
        XCTAssertEqual(missing.issues.map(\.path), ["schemaVersion"])
    }

    func testDocument_exportNeverContainsSecretValues() throws {
        let document = SettingsDocument(settings: self.defaults, apiKeys: ["openai": true])
        let text = try XCTUnwrap(String(data: document.encodedJSON(), encoding: .utf8))
        XCTAssertTrue(text.contains(#""isSet" : true"#))
        guard case .object(let root) = document.jsonValue, case .object(let keys)? = root["apiKeys"] else {
            return XCTFail("apiKeys missing")
        }
        XCTAssertEqual(keys["openai"], .object(["isSet": .bool(true)]))
    }

    func testDocument_filtersByKeysAndPrefix() {
        let document = SettingsDocument(
            settings: ["ttsSpeed": .double(1), "ttsPitch": .double(0), "runAtLogin": .bool(true)]
        )
        XCTAssertEqual(Set(document.filtered(keys: nil, prefix: "tts").settings.keys), ["ttsSpeed", "ttsPitch"])
        XCTAssertEqual(Set(document.filtered(keys: ["ttsSpeed", "runAtLogin"], prefix: "tts").settings.keys),
                       ["ttsSpeed"])
    }

    // MARK: - Validator

    func testValidator_reportsEachBadFieldWithItsPath() {
        let report = self.validate([
            "noSuchSetting": .bool(true),
            "ttsSpeed": .double(9),
            "showHUDDuringSessions": .string("yes"),
            "appearance": .string("purple"),
            "postProcessingModel": .string(""),
            "batchTranscriptionModel": .string("made-up/model"),
            "livePolishDebounceMs": .double(1.5)
        ])
        XCTAssertFalse(report.isValid)
        XCTAssertEqual(Set(self.errorPaths(report)), [
            "settings.noSuchSetting", "settings.ttsSpeed", "settings.showHUDDuringSessions",
            "settings.appearance", "settings.postProcessingModel", "settings.batchTranscriptionModel",
            "settings.livePolishDebounceMs"
        ])
    }

    func testValidator_returnsOnlyRealChangesInCanonicalForm() {
        let report = self.validate(["ttsSpeed": .int(2), "ttsPitch": .double(0), "livePolishDebounceMs": .double(800)])
        XCTAssertTrue(report.isValid)
        XCTAssertEqual(report.changes, ["ttsSpeed": .double(2), "livePolishDebounceMs": .int(800)])
    }

    func testValidator_readOnlyFieldsMayOnlyRepeatTheirCurrentValue() {
        XCTAssertTrue(self.validate(["enableAutomationServer": .bool(false)]).isValid)
        XCTAssertEqual(self.errorPaths(self.validate(["enableAutomationServer": .bool(true)])),
                       ["settings.enableAutomationServer"])
        XCTAssertEqual(self.errorPaths(self.validate(["allowAutomationConfigurationChanges": .bool(true)])),
                       ["settings.allowAutomationConfigurationChanges"])
    }

    func testValidator_importKeepsDifferingReadOnlyValuesWithAWarning() {
        let context = SettingsValidationContext(currentValues: self.defaults, ignoresReadOnlyChanges: true)
        let report = SettingsValidator.validate(
            settings: ["enableAutomationServer": .bool(true), "ttsSpeed": .double(1.5)], context: context)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.warnings.map(\.path), ["settings.enableAutomationServer"])
        XCTAssertEqual(report.changes, ["ttsSpeed": .double(1.5)])
    }

    func testValidator_acceptsCatalogueModelsAndHostSuppliedOnes() throws {
        let live = try XCTUnwrap(ModelCatalog.liveTranscription.first?.id)
        XCTAssertEqual(self.validate(["liveTranscriptionModel": .string(live)]).errors, [])
        let context = SettingsValidationContext(
            currentValues: self.defaults, additionalModelIDs: [.localTranscription: ["local/imported/model"]]
        )
        let report = SettingsValidator.validate(
            settings: ["localTranscriptionModel": .string("local/imported/model")], context: context
        )
        XCTAssertEqual(report.errors, [])
    }

    func testValidator_autoCleanNeedsLiveNativeAndACapableLiveModel() throws {
        let capable = try XCTUnwrap(ModelCatalog.liveTranscription.first {
            ModelCatalog.liveCapabilities(for: $0.id).supportedSpeedModes.contains(.livePolish)
        }?.id)
        var current = self.defaults
        current["liveTranscriptionModel"] = .string(capable)
        current["postProcessingEnabled"] = .bool(false)

        let livePolish: [String: JSONValue] = ["speedMode": .string("livePolish")]
        XCTAssertEqual(self.validate(livePolish, current: current).errors, [])

        current["transcriptionMode"] = .string("batchRemote")
        XCTAssertEqual(self.errorPaths(self.validate(livePolish, current: current)), ["settings.speedMode"])

        if let incapable = ModelCatalog.liveTranscription.first(where: {
            !ModelCatalog.liveCapabilities(for: $0.id).supportedSpeedModes.contains(.livePolish)
        })?.id {
            current["transcriptionMode"] = .string("liveNative")
            current["liveTranscriptionModel"] = .string(incapable)
            XCTAssertEqual(self.errorPaths(self.validate(livePolish, current: current)), ["settings.speedMode"])
        }
    }

    func testValidator_cleanupAndAutoCleanAreExclusive() {
        var current = self.defaults
        current["speedMode"] = .string("instant")
        current["postProcessingEnabled"] = .bool(false)
        let both: [String: JSONValue] = ["postProcessingEnabled": .bool(true), "speedMode": .string("livePolish")]
        XCTAssertTrue(self.errorPaths(self.validate(both, current: current)).contains("settings.postProcessingEnabled"))
    }

    func testValidator_otherPlatformsKeysAreKeptButIgnored() throws {
        let foreign = try XCTUnwrap(SettingsSchema.catalogueKeys.subtracting(SettingsSchema.keys).sorted().first)
        let document = SettingsDocument(platform: "iOS", settings: [foreign: .bool(true)])
        let context = SettingsValidationContext(currentValues: self.defaults)
        let report = SettingsValidator.validate(document, context: context)
        XCTAssertTrue(report.isValid)
        XCTAssertEqual(report.ignoredKeys, [foreign])
        XCTAssertEqual(report.changes, [:])
        XCTAssertEqual(report.warnings.first?.path, "platform")
    }

    // MARK: - Windows and Linux (#1608)

    private func desktopContext(_ platform: SettingsSchemaPlatform = .windows) -> SettingsValidationContext {
        var context = SettingsValidationContext(currentValues: Dictionary(uniqueKeysWithValues:
            SettingsSchema.fields(for: platform).compactMap { field in field.defaultValue.map { (field.key, $0) } }))
        context.platform = platform
        return context
    }

    func testDesktopSchema_coversEveryPortablePreferenceAndItsDefaultsPass() {
        let keys = Set(SettingsSchema.keys(for: .windows))
        XCTAssertEqual(SettingsSchema.keys(for: .linux), SettingsSchema.keys(for: .windows))
        XCTAssertEqual(keys.count, SettingsSchema.keys(for: .windows).count)
        XCTAssertEqual(
            keys.subtracting([ApplicationPreferenceKey.enableAutomationServer.rawValue]),
            Set(DesktopConfiguration.fields.map(\.key)).subtracting([DesktopConnectionPreWarming.approvalProjectionKey])
        )
        let context = self.desktopContext()
        let report = SettingsValidator.validate(settings: context.currentValues, context: context)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.changes, [:])
        XCTAssertTrue(SettingsSchema.fields(for: .windows).allSatisfy { !$0.isSensitive })
        XCTAssertTrue(try DesktopConfiguration(values: context.currentValues.mapValues(AnyCodable.init)).values
            .keys.contains("showHUD"))
    }

    func testDesktopSchema_grantAndConsentAreReadOnlyAndRangesMatchTheDesktopCatalogue() throws {
        for key in ["allowAutomationConfigurationChanges", "enableAutomationServer", "analyticsEnabled"] {
            XCTAssertEqual(SettingsSchema.field(forKey: key, platform: .linux)?.isReadOnly, true, key)
        }
        let report = SettingsValidator.validate(
            settings: ["holdThreshold": .double(9), "showHUD": .string("yes"),
                       "autoCorrectionsPromotionThreshold": .double(3.5)],
            context: self.desktopContext())
        XCTAssertEqual(Set(self.errorPaths(report)), [
            "settings.holdThreshold", "settings.showHUD", "settings.autoCorrectionsPromotionThreshold"
        ])
        let modulate = try XCTUnwrap(DesktopConfiguration.modulatePreferenceKeys.first)
        XCTAssertEqual(SettingsSchema.field(forKey: modulate, platform: .windows)?.kind, .boolean)
    }

    func testDesktopSchema_macOnlyKeysAreKeptButIgnoredAndDesktopsShareDocuments() throws {
        let macOnly = try XCTUnwrap(Set(SettingsSchema.keys(for: .macOS))
            .subtracting(SettingsSchema.keys(for: .windows)).sorted().first)
        let fromLinux = SettingsValidator.validate(
            SettingsDocument(platform: "linux", settings: [macOnly: .bool(true)]), context: self.desktopContext())
        XCTAssertTrue(fromLinux.isValid)
        XCTAssertEqual(fromLinux.ignoredKeys, [macOnly])
        XCTAssertNotEqual(fromLinux.warnings.first?.path, "platform")
        let fromMac = SettingsValidator.validate(
            SettingsDocument(platform: "macOS", settings: [:]), context: self.desktopContext(.linux))
        XCTAssertEqual(fromMac.warnings.first?.path, "platform")
        XCTAssertTrue(SettingsSchema.platforms(forKey: "showHUD").contains(.windows))
    }

    // MARK: - iOS (#1608)

    func testIOSSchema_defaultsPassNoSecretsAndEveryKeyIsSearchableOnIPhone() {
        let fields = SettingsSchema.fields(for: .iOS)
        XCTAssertEqual(Set(fields.map(\.key)).count, fields.count)
        XCTAssertTrue(fields.allSatisfy { !$0.isSensitive && !$0.key.hasSuffix("APIKey") })
        let indexed = Set(SettingsSearchCatalog.entries(for: .iOS).flatMap(\.settingKeys))
        XCTAssertEqual(Set(fields.map(\.key)).subtracting(indexed), [])

        var context = SettingsValidationContext(currentValues: Dictionary(uniqueKeysWithValues:
            fields.compactMap { field in field.defaultValue.map { (field.key, $0) } }))
        context.platform = .iOS
        let report = SettingsValidator.validate(settings: context.currentValues, context: context)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.changes, [:])
        XCTAssertEqual(
            SettingsSchema.field(forKey: "transcriptClipboardLifetime", platform: .iOS)?.defaultValue,
            .int(SettingsSchema.iOSTranscriptClipboardLifetimes[1]))
    }

    func testIOSSchema_rejectsMacValuesAndKeepsMacOnlyKeys() throws {
        var context = SettingsValidationContext(currentValues: ["transcriptionMode": .string("streaming")])
        context.platform = .iOS
        let macOnly = try XCTUnwrap(Set(SettingsSchema.keys(for: .macOS))
            .subtracting(SettingsSchema.keys(for: .iOS)).sorted().first)
        let report = SettingsValidator.validate(
            SettingsDocument(platform: "macOS", settings: [
                "transcriptionMode": .string("liveNative"), macOnly: .bool(true),
                "transcriptReadyNotificationsEnabled": .bool(true)
            ]),
            context: context)
        XCTAssertEqual(
            Set(self.errorPaths(report)),
            ["settings.transcriptionMode", "settings.transcriptReadyNotificationsEnabled"])
        XCTAssertEqual(report.ignoredKeys, [macOnly])
        XCTAssertEqual(report.warnings.first?.path, "platform")
    }
}
