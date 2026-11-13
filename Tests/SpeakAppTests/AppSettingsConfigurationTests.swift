import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// The macOS side of the raw configuration (issue #1546): one binding per
/// schema key, all-or-nothing apply, no secrets and automation write opt-in.
@MainActor
final class AppSettingsConfigurationTests: XCTestCase {
    typealias JSONValue = AnyCodable.JSONValue

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "AppSettingsConfigurationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeSettings() -> AppSettings {
        AppSettings(
            defaults: defaults,
            system: AppSettings.SystemDependencies(
                fileManager: .default, setActivationPolicy: { _ in }, registerLoginItem: { _ in }
            )
        )
    }

    private func makeConfiguration(
        _ settings: AppSettings, hasKey: @escaping @MainActor (String) async -> Bool = { _ in false }
    ) -> AppSettingsConfiguration {
        AppSettingsConfiguration(settings: settings, hasAPIKey: hasKey)
    }

    func testEverySchemaKeyHasABinding_andNoBindingIsUnschemed() {
        XCTAssertEqual(Set(AppSettingsConfiguration.bindings.keys), Set(SettingsSchema.keys))
        for field in SettingsSchema.fields {
            XCTAssertEqual(
                AppSettingsConfiguration.bindings[field.key]?.write == nil, field.isReadOnly,
                "\(field.key): read-only fields have no writer, writable ones do")
        }
    }

    /// Persisted settings deliberately left out of the raw configuration, with the reason.
    private static let unschemedSettings: [String: String] = [
        "trackedAPIKeyIdentifiers": "Bookkeeping for stored keys; exported as apiKeys.<id>: true|false.",
        "recoveredTranscriptionKeywords": "Competing keyword edits kept until restored or discarded in Settings; not set directly.",
        "assemblyAIKeyterms": "Older alias of transcriptionKeywords, which the schema carries.",
    ]

    func testEveryPersistedMacSettingHasASchemaField() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/SpeakApp/Settings")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("AppSettings") && $0.pathExtension == "swift" }
        let regex = try NSRegularExpression(pattern: #"@Published\s+(?:private\(set\)\s+)?var\s+(\w+)"#)
        var published: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let range = Range(match.range(at: 1), in: source) { published.append(String(source[range])) }
            }
        }
        XCTAssertFalse(published.isEmpty)
        let missing = published.filter { SettingsSchema.field(forKey: $0) == nil && Self.unschemedSettings[$0] == nil }
        XCTAssertTrue(missing.isEmpty, "Add SettingsSchema fields (and bindings) for: \(missing.sorted())")
    }

    func testFreshSettingsMatchSchemaDefaults() {
        let values = makeConfiguration(makeSettings()).currentValues()
        for field in SettingsSchema.fields {
            guard let expected = field.defaultValue else { continue }
            XCTAssertEqual(values[field.key], expected, "Default for \(field.key)")
        }
    }

    func testEveryAllowedEnumValueIsAcceptedByTheApp() throws {
        for field in SettingsSchema.fields where field.kind == .enumeration && !field.isReadOnly {
            let binding = try XCTUnwrap(AppSettingsConfiguration.bindings[field.key])
            for value in field.allowedValues ?? [] {
                let settings = makeSettings()
                if field.key == "speedMode" { try prepareForAutoClean(settings) }
                binding.write?(settings, .string(value))
                XCTAssertEqual(binding.read(settings), .string(value), "\(field.key) = \(value)")
            }
        }
    }

    func testCurrentDocumentValidatesWithoutChanges() async {
        let configuration = makeConfiguration(makeSettings())
        let report = configuration.validate(document: await configuration.document())
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.changes, [:])
    }

    func testApply_isAllOrNothing_whenAnyChangeIsInvalid() {
        let settings = makeSettings()
        let configuration = makeConfiguration(settings)
        let before = configuration.currentValues()
        let report = configuration.validate(changes: [
            "ttsSpeed": .double(1.5),
            "appearance": .string("sepia"),
            "silenceDuration": .string("long"),
        ])
        XCTAssertEqual(report.errors.map(\.path).sorted(), ["settings.appearance", "settings.silenceDuration"])
        XCTAssertThrowsError(try configuration.apply(report))
        XCTAssertEqual(configuration.currentValues(), before)
    }

    func testApply_rollsBackEverySetting_whenOneDoesNotStick() {
        let settings = makeSettings()
        let configuration = makeConfiguration(settings)
        let before = configuration.currentValues()
        // A report that slipped past validation: the app rejects the enum value.
        let report = SettingsValidationReport(changes: ["ttsSpeed": .double(1.5), "appearance": .string("sepia")])
        XCTAssertThrowsError(try configuration.apply(report)) { error in
            let paths = (error as? AppSettingsConfiguration.ApplyError)?.issues.map(\.path)
            XCTAssertEqual(paths, ["settings.appearance"])
        }
        XCTAssertEqual(configuration.currentValues(), before)
    }

    func testExportImportRoundTripsWithoutLoss_andKeepsOtherPlatformsKeys() async throws {
        let settings = makeSettings()
        let configuration = makeConfiguration(settings)
        let foreignKey = try XCTUnwrap(
            SettingsSchema.catalogueKeys.subtracting(SettingsSchema.keys).sorted().first)

        var document = await configuration.document()
        document.settings["ttsPitch"] = .double(1.25)
        document.settings["recordingSoundVolume"] = .double(0.7)
        document.settings[foreignKey] = .bool(true)
        let parsed = try SettingsDocument.parse(document.encodedJSON()).get()
        let report = configuration.validate(document: parsed)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.ignoredKeys, [foreignKey])
        try configuration.apply(report, foreign: AppSettingsConfiguration.foreignValues(of: parsed, report: report))

        let reloaded = makeConfiguration(makeSettings())
        let exported = try SettingsDocument.parse(await reloaded.document().encodedJSON()).get()
        XCTAssertEqual(Set(exported.settings.keys), Set(parsed.settings.keys))
        XCTAssertEqual(exported.settings[foreignKey], .bool(true))
        XCTAssertEqual(reloaded.validate(document: parsed).changes, [:], "Nothing lost on the way round")
        XCTAssertEqual(settings.recordingSoundVolume, 0.7, accuracy: 0.0001)
    }

    func testImportedDocumentKeepsReadOnlyValues_withAWarning() async throws {
        let settings = makeSettings()
        let configuration = makeConfiguration(settings)
        var document = await configuration.document()
        document.settings["enableAutomationServer"] = .bool(!settings.enableAutomationServer)
        let report = configuration.validate(document: document)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.warnings.map(\.path), ["settings.enableAutomationServer"])
        XCTAssertNil(report.changes["enableAutomationServer"])
    }

    func testDocumentNeverContainsSecrets_onlyWhetherKeysAreStored() async throws {
        let settings = makeSettings()
        settings.registerAPIKeyIdentifier("openai")
        settings.registerAPIKeyIdentifier("deepgram")
        let configuration = makeConfiguration(settings) { $0 == "openai" }
        let document = await configuration.document()
        XCTAssertEqual(document.apiKeys, ["openai": true, "deepgram": false])
        XCTAssertTrue(SettingsSchema.fields.allSatisfy { !$0.isSensitive })
        let json = try XCTUnwrap(String(data: document.encodedJSON(), encoding: .utf8))
        XCTAssertFalse(json.contains("sk-"), "No key material in the export")
        XCTAssertEqual(Set(document.settings.keys), Set(SettingsSchema.keys))
    }

    func testRecordingsDirectoryMustBeAnExistingAbsoluteFolder() {
        let configuration = makeConfiguration(makeSettings())
        let relative = configuration.validate(changes: ["recordingsDirectory": .string("relative/path")])
        XCTAssertEqual(relative.errors.map(\.path), ["settings.recordingsDirectory"])
        let missing = configuration.validate(changes: ["recordingsDirectory": .string("/no/such/folder/\(UUID())")])
        XCTAssertEqual(missing.errors.map(\.path), ["settings.recordingsDirectory"])
        let existing = configuration.validate(changes: ["recordingsDirectory": .string(NSTemporaryDirectory())])
        XCTAssertEqual(existing.errors, [])
    }

    // MARK: Automation

    func testAutomationSet_refusesWritesWithoutOptIn_butAllowsDryRun() throws {
        let settings = makeSettings()
        let configuration = makeConfiguration(settings)
        let before = configuration.currentValues()
        XCTAssertThrowsError(
            try configuration.automationSet(["ttsSpeed": .double(1.5)], dryRun: false, writesAllowed: false)
        ) { error in
            XCTAssertEqual(error as? AutomationError, AutomationConfiguration.writesNotAllowed)
        }
        let dryRun = try configuration.automationSet(["ttsSpeed": .double(1.5)], dryRun: true, writesAllowed: false)
        XCTAssertEqual(object(dryRun)["applied"], .bool(false))
        XCTAssertEqual(object(dryRun)["changes"], .object(["ttsSpeed": .double(1.5)]))
        XCTAssertEqual(configuration.currentValues(), before)
    }

    func testAutomationSet_appliesSeveralValuesTogether() throws {
        let settings = makeSettings()
        let configuration = makeConfiguration(settings)
        let compact = !settings.showCompactHUD
        let changes: [String: JSONValue] = [
            "ttsSpeed": .double(1.5), "showCompactHUD": .bool(compact), "livePolishDebounceMs": .int(400),
        ]
        let result = try configuration.automationSet(changes, dryRun: false, writesAllowed: true)
        XCTAssertEqual(object(result)["applied"], .bool(true))
        XCTAssertEqual(settings.ttsSpeed, 1.5, accuracy: 0.0001)
        XCTAssertEqual(settings.livePolishDebounceMs, 400)
        XCTAssertEqual(settings.showCompactHUD, compact)
    }

    func testAutomationSet_reportsEveryInvalidChange_andChangesNothing() {
        let settings = makeSettings()
        let configuration = makeConfiguration(settings)
        let before = configuration.currentValues()
        XCTAssertThrowsError(try configuration.automationSet(
            ["ttsSpeed": .double(9), "liveTranscriptionModel": .string("nope/model"), "bogus": .bool(true)],
            dryRun: false, writesAllowed: true)
        ) { error in
            let message = (error as? AutomationError)?.message ?? ""
            for path in ["settings.ttsSpeed", "settings.liveTranscriptionModel", "settings.bogus"] {
                XCTAssertTrue(message.contains(path), "\(path) in \(message)")
            }
        }
        XCTAssertEqual(configuration.currentValues(), before)
    }

    /// Auto-Clean needs live transcription with a model that supports it.
    private func prepareForAutoClean(_ settings: AppSettings) throws {
        let model = try XCTUnwrap(ModelCatalog.liveTranscription.first {
            ModelCatalog.liveCapabilities(for: $0.id).supportedSpeedModes.contains(.livePolish)
        })
        let configuration = makeConfiguration(settings)
        try configuration.apply(configuration.validate(changes: [
            "transcriptionMode": .string("liveNative"), "liveTranscriptionModel": .string(model.id),
            "postProcessingEnabled": .bool(false),
        ]))
    }

    private func object(_ result: AutomationResult) -> [String: JSONValue] {
        guard case .object(let object)? = result.configuration?.storage else { return [:] }
        return object
    }
}
