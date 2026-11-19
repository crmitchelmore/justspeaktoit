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
        let stores = makeStores()
        return (stores.settings, stores.configuration)
    }

    private struct Fixture {
        let settings: AppSettings
        let voice: IOSVoiceOutputSettings
        let configuration: IOSSettingsConfiguration
    }

    private func makeStores() -> Fixture {
        let settings = AppSettings(defaults: defaults, loadsSecureStorage: false)
        let voice = IOSVoiceOutputSettings(defaults: defaults)
        return Fixture(
            settings: settings, voice: voice,
            configuration: IOSSettingsConfiguration(settings: settings, voice: voice) { _ in false })
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
        XCTAssertEqual(allowed("ttsProvider"), VoiceOutputProvider.allCases.map(\.rawValue))
        XCTAssertEqual(allowed("sonioxTTSRegion"), SonioxTTSRegion.allCases.map(\.rawValue))
        let speedRange = SettingsSchema.field(forKey: "ttsSpeed", platform: .iOS)?.range
        for provider in VoiceOutputProvider.allCases {
            XCTAssertEqual(speedRange?.clamped(to: provider.speedRange), provider.speedRange, provider.rawValue)
        }
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

    // MARK: - Read aloud (#1671)

    func testReadAloudSettingsRoundTripThroughTheRawConfiguration() async throws {
        let fixture = makeStores()
        let (voice, configuration) = (fixture.voice, fixture.configuration)
        var document = await configuration.document()
        XCTAssertEqual(document.settings["ttsProvider"], .string(VoiceOutputProvider.defaultProvider.rawValue))
        XCTAssertEqual(document.settings["ttsSpeed"], .double(1))

        let sonioxVoice = SonioxTTSCatalog.voices.last!
        document.settings["ttsProvider"] = .string("soniox")
        document.settings["ttsModel"] = .string(SonioxTTSCatalog.defaultModel.rawValue)
        document.settings["ttsVoice"] = .string(sonioxVoice.providerVoiceID)
        document.settings["ttsSpeed"] = .double(1.2)
        document.settings["ttsLanguageIdentifier"] = .string("en_GB")
        document.settings["sonioxTTSRegion"] = .string("eu")
        let report = configuration.validate(document: document)
        XCTAssertEqual(report.errors, [])
        try configuration.apply(report)

        XCTAssertEqual(voice.ttsProvider, .soniox)
        XCTAssertEqual(voice.ttsVoice, sonioxVoice.providerVoiceID)
        XCTAssertEqual(voice.ttsVoiceName, sonioxVoice.displayName)
        XCTAssertEqual(voice.ttsSpeed, 1.2)
        XCTAssertEqual(voice.ttsLanguageIdentifier, "en_GB")
        XCTAssertEqual(voice.sonioxRegion, .europe)

        // The applied selection is what the app keeps and reloads.
        voice.validateVoiceModelCombination()
        let reloaded = IOSVoiceOutputSettings(defaults: defaults)
        let exported = await configuration.document()
        for key in ["ttsProvider", "ttsModel", "ttsVoice", "ttsSpeed", "ttsLanguageIdentifier", "sonioxTTSRegion"] {
            XCTAssertEqual(exported.settings[key], document.settings[key], key)
        }
        XCTAssertEqual(reloaded.ttsProvider, .soniox)
        XCTAssertEqual(reloaded.ttsVoice, sonioxVoice.providerVoiceID)
        XCTAssertEqual(reloaded.ttsSpeed, 1.2)
        XCTAssertEqual(reloaded.sonioxRegion, .europe)
    }

    func testOpenRouterSpeechSelectionApplies() throws {
        let fixture = makeStores()
        let (voice, configuration) = (fixture.voice, fixture.configuration)
        let selection = OpenRouterSpeechSelection(modelID: "example/speech", voice: "nova")
        let report = configuration.validate(changes: [
            "ttsProvider": .string("openrouter"), "ttsModel": .string(selection.id), "ttsVoice": .string("nova")
        ])
        XCTAssertEqual(report.errors, [])
        try configuration.apply(report)
        XCTAssertEqual(voice.ttsProvider, .openrouter)
        XCTAssertEqual(voice.ttsModel, selection.id)
        XCTAssertEqual(voice.ttsVoiceName, "nova")
    }

    func testInvalidReadAloudSettingsChangeNothing() {
        let fixture = makeStores()
        let (voice, configuration) = (fixture.voice, fixture.configuration)
        let before = configuration.currentValues()
        let report = configuration.validate(changes: [
            "ttsProvider": .string("soniox"),
            "ttsModel": .string(SonioxTTSCatalog.defaultModel.rawValue),
            "ttsVoice": .string(VoiceOutputProvider.defaultSelection.voice),
            "ttsSpeed": .double(1.8),
            "ttsLanguageIdentifier": .string("tlh_KL"),
            "sonioxTTSRegion": .string("mars")
        ])
        XCTAssertEqual(
            Set(report.errors.map(\.path)),
            ["settings.ttsVoice", "settings.ttsSpeed", "settings.ttsLanguageIdentifier",
             "settings.sonioxTTSRegion"])
        XCTAssertThrowsError(try configuration.apply(report))
        XCTAssertEqual(voice.ttsProvider, VoiceOutputProvider.defaultProvider)
        XCTAssertEqual(configuration.currentValues(), before)

        let wrongModel = configuration.validate(changes: ["ttsModel": .string("not-a-model")])
        XCTAssertEqual(wrongModel.errors.map(\.path), ["settings.ttsModel"])
    }
}
#endif
