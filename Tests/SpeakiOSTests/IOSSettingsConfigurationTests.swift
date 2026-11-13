#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// The iPhone raw configuration editor (#1608): every field binds, a fresh
/// install matches the schema's defaults, and documents apply all or none.
@MainActor
final class IOSSettingsConfigurationTests: XCTestCase {
    typealias JSONValue = AnyCodable.JSONValue

    private var defaults: UserDefaults!
    private let suiteName = "IOSSettingsConfigurationTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeConfiguration() -> (AppSettings, IOSSettingsConfiguration) {
        let settings = AppSettings(defaults: defaults, loadsSecureStorage: false)
        return (settings, IOSSettingsConfiguration(settings: settings) { _ in false })
    }

    func testEverySchemaFieldIsBoundAndAFreshInstallMatchesItsDefaults() {
        let (_, configuration) = makeConfiguration()
        XCTAssertEqual(Set(IOSSettingsConfiguration.bindings.keys), Set(SettingsSchema.keys(for: .iOS)))
        let current = configuration.currentValues()
        for field in SettingsSchema.fields(for: .iOS) {
            guard let value = field.defaultValue else { continue }
            XCTAssertEqual(current[field.key], value, field.key)
        }
    }

    func testAllowedValuesMatchTheAppEnums() {
        func allowed(_ key: String) -> [String]? { SettingsSchema.field(forKey: key, platform: .iOS)?.allowedValues }
        XCTAssertEqual(allowed("transcriptionMode"), IOSTranscriptionMode.allCases.map(\.rawValue))
        XCTAssertEqual(allowed("hardwareTriggerDestination"), HardwareTriggerDestination.allCases.map(\.rawValue))
        XCTAssertEqual(
            SettingsSchema.iOSTranscriptClipboardLifetimes, TranscriptClipboardLifetime.allCases.map(\.rawValue))
        XCTAssertEqual(
            SettingsSchema.field(forKey: "autoStopSilenceSeconds", platform: .iOS)?.range,
            CaptureEndPointingPolicy.silenceWindowRange)
    }

    func testDocumentHasNoSecretsAndListsStoredKeys() async {
        let (_, configuration) = makeConfiguration()
        let document = await configuration.document()
        XCTAssertTrue(document.settings.keys.allSatisfy { !$0.hasSuffix("APIKey") })
        XCTAssertEqual(document.platform, "iOS")
        XCTAssertEqual(Set(document.apiKeys.keys), Set(AppSettings.syncedAPIKeys.map(\.identifier)))
    }

    func testValidDocumentApplies() throws {
        let (settings, configuration) = makeConfiguration()
        var document = configuration.defaultsDocument()
        document.settings["autoStopSilenceSeconds"] = .int(5)
        document.settings["hardwareTriggerDestination"] = .string("historyOnly")
        document.settings["transcriptClipboardLifetime"] = .int(900)
        let report = configuration.validate(document: document)
        XCTAssertEqual(report.errors, [])
        try configuration.apply(report)
        XCTAssertEqual(settings.autoStopSilenceSeconds, 5)
        XCTAssertEqual(settings.hardwareTriggerDestination, .historyOnly)
        XCTAssertEqual(settings.transcriptClipboardLifetime, .fifteenMinutes)
    }

    func testInvalidDocumentChangesNothing() {
        let (settings, configuration) = makeConfiguration()
        let before = configuration.currentValues()
        var document = configuration.defaultsDocument()
        document.settings["autoStartRecording"] = .bool(true)
        document.settings["transcriptClipboardLifetime"] = .int(120)
        document.settings["autoStopSilenceSeconds"] = .double(30)
        let report = configuration.validate(document: document)
        XCTAssertEqual(
            Set(report.errors.map(\.path)),
            ["settings.transcriptClipboardLifetime", "settings.autoStopSilenceSeconds"])
        XCTAssertThrowsError(try configuration.apply(report))
        XCTAssertFalse(settings.autoStartRecording)
        XCTAssertEqual(configuration.currentValues(), before)
    }

    func testForeignKeysSurviveAnExportRoundTrip() async throws {
        let (_, configuration) = makeConfiguration()
        let document = SettingsDocument(platform: "macOS", settings: ["showCompactHUD": .bool(true)])
        let report = configuration.validate(document: document)
        XCTAssertTrue(report.isValid)
        try configuration.apply(report, foreign: IOSSettingsConfiguration.foreignValues(of: document, report: report))
        let exported = await configuration.document()
        XCTAssertEqual(exported.settings["showCompactHUD"], .bool(true))
    }
}
#endif
