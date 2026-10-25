import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

extension DesktopHostAutomationTests {
    func testFileWithoutProfile_UsesImportedPreferredLocaleAfterRestart() async throws {
        let fixture = AutomationFixtureEffects()
        try await prepareAutomationLanguage("fr_FR", effects: fixture)
        try await use(fixture)
        let file = try automationLanguageFile()
        let bytes = try Data(contentsOf: file)
        _ = try await controller.automationTranscribeFile(at: file)
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.model, "openai/whisper-1")
        XCTAssertEqual(request.language, "fr_FR")
        XCTAssertFalse(request.historySaved)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let history = try await controller.store.records()
        XCTAssertTrue(history.isEmpty)
        XCTAssertTrue(fixture.base.outputs.isEmpty)
        XCTAssertEqual(fixture.postProcessingCalls, 0)
    }

    func testAutomaticLocale_DoesNotReuseAnEarlierExplicitLanguage() async throws {
        let fixture = AutomationFixtureEffects()
        try await prepareAutomationLanguage("en_GB", effects: fixture)
        let file = try automationLanguageFile()
        _ = try await controller.automationTranscribeFile(at: file)
        try await importValues(["preferredLocale": AnyCodable(.string("automatic"))])
        _ = try await controller.automationTranscribeFile(at: file)
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(try XCTUnwrap(fixture.requests.first).language, "en_GB")
        XCTAssertNil(try XCTUnwrap(fixture.requests.last).language)
        let configuration = try await controller.configuration()
        XCTAssertEqual(configuration.values["preferredLocale"], AnyCodable(.string("automatic")))
    }

    func testProfileLanguage_InheritsOverridesOrExplicitlyRequestsDetection() async throws {
        let fixture = AutomationFixtureEffects()
        try await prepareAutomationLanguage("fr_FR", effects: fixture)
        let file = try automationLanguageFile()
        let cases: [(String?, String?)] = [(nil, "fr_FR"), ("en_GB", "en_GB"), ("automatic", nil)]
        for (languageOverride, expected) in cases {
            try await controller.automationFixtureProfile(DictationProfile(
                name: "Language profile", transcriptionModelID: "openai/whisper-1", polishEnabled: false,
                languageIdentifier: languageOverride, transcriptionRouting: .remoteBatch
            ))
            _ = try await controller.automationTranscribeFile(at: file)
            let request = try XCTUnwrap(fixture.requests.last)
            XCTAssertEqual(request.model, "openai/whisper-1")
            XCTAssertEqual(request.language, expected)
            XCTAssertFalse(request.historySaved)
        }
        let configuration = try await controller.configuration()
        XCTAssertEqual(configuration.language, "fr_FR")
        XCTAssertEqual(fixture.requests.count, cases.count)
        XCTAssertEqual(fixture.postProcessingCalls, 0)
    }

    func testFileCommand_KeepsCapturedLanguageWhileTheNextCommandUsesTheNewPreference() async throws {
        let entered = expectation(description: "first file request reached the transcription effect")
        entered.assertForOverFulfill = false
        let fixture = AutomationFixtureEffects(blocking: true, onEnter: { entered.fulfill() })
        try await prepareAutomationLanguage("en_GB", effects: fixture)
        let file = try automationLanguageFile()
        let app = try XCTUnwrap(controller)
        let command = Task { try await app.automationTranscribeFile(at: file) }
        defer { fixture.release(); command.cancel() }
        await fulfillment(of: [entered], timeout: 10)
        try await importValues(["preferredLocale": AnyCodable(.string("fr_FR"))])
        fixture.release()
        _ = try await command.value
        _ = try await app.automationTranscribeFile(at: file)
        XCTAssertEqual(fixture.requests.map(\.language), ["en_GB", "fr_FR"])
        XCTAssertTrue(fixture.requests.allSatisfy { !$0.historySaved })
        let history = try await app.store.records()
        XCTAssertTrue(history.isEmpty)
        XCTAssertTrue(fixture.base.outputs.isEmpty)
    }

    func testDictationWithoutProfile_PreservesTheAdmittedLocaleAndRejectsAnActiveImport() async throws {
        let fixture = AutomationFixtureEffects()
        try await prepareAutomationLanguage("en_GB", effects: fixture)
        _ = try await controller.automationStartDictation()
        do {
            try await importValues(["preferredLocale": AnyCodable(.string("fr_FR"))])
            XCTFail("Active dictation accepted a configuration import")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Finish dictation"))
        }
        _ = try await controller.automationStopDictation()
        let request = try XCTUnwrap(fixture.requests.last)
        XCTAssertEqual(request.language, "en_GB")
        XCTAssertTrue(request.historySaved)
        let history = try await controller.store.records()
        let record = try XCTUnwrap(history.first)
        XCTAssertEqual(record.languageIdentifier, "en_GB")
        XCTAssertNil(record.profileName)
    }

    private func prepareAutomationLanguage(
        _ locale: String, effects: AutomationFixtureEffects
    ) async throws {
        try await use(effects)
        let model = "openai/whisper-1"
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic-language-key", name: credential)
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == model })
        let selected = await controller.selectModel(index)
        XCTAssertTrue(selected)
        try await importValues(["preferredLocale": AnyCodable(.string(locale))])
    }

    private func automationLanguageFile() throws -> URL {
        let file = directory.appendingPathComponent("language.wav")
        let bytes = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000))
        try bytes.write(to: file)
        return file
    }
}
