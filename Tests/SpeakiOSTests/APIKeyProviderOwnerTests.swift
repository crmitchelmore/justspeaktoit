#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class APIKeyCredentialWriterTests: XCTestCase {
    private var suiteName: String!
    private var settings: AppSettings!

    override func setUp() async throws {
        suiteName = "APIKeyCredentialWriterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let storage = SecureStorage(
            configuration: .init(service: suiteName), permissionsChecker: WriterDeniedKeychainAccess()
        )
        settings = AppSettings(defaults: defaults, loadsSecureStorage: false, credentialStorage: storage)
    }

    override func tearDown() async throws {
        await settings.awaitPendingSecretWrites()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
    }

    func testStore_writesOnlyTheSettingForTheEntry() {
        let writer = APIKeyCredentialWriter(settings: settings)
        writer.store("dg", for: "deepgram")
        writer.store("rev", for: "revai")
        writer.store("step", for: "stepfun")
        writer.store("gq", for: "groq")

        XCTAssertEqual(settings.deepgramAPIKey, "dg")
        XCTAssertEqual(settings.revAIAPIKey, "rev")
        XCTAssertEqual(settings.stepfunAPIKey, "step")
        XCTAssertEqual(settings.groqAPIKey, "gq")
        XCTAssertEqual(settings.batchAPIKey(for: "groq/whisper-large-v3-turbo"), "gq")
        XCTAssertEqual(settings.openAIAPIKey, "")
        XCTAssertEqual(settings.gladiaAPIKey, "")
    }

    func testStore_unknownEntryStoresTheGladiaKeyAsItAlwaysHas() {
        let writer = APIKeyCredentialWriter(settings: settings)
        writer.store("gl", for: "gladia")
        XCTAssertEqual(settings.gladiaAPIKey, "gl")
        writer.store("future", for: "some-future-provider")
        XCTAssertEqual(settings.gladiaAPIKey, "future")
    }

    func testValidationFailure_providersWithoutAProbeAcceptAnyKey() async {
        let writer = APIKeyCredentialWriter(settings: settings)
        for id in ["openai", "openrouter", "soniox", "revai", "mistral", "smallest", "gladia"] {
            let failure = await writer.validationFailure(of: "anything", for: id)
            XCTAssertNil(failure, "\(id) is checked when a session connects")
        }
    }

    func testValidationFailure_alibabaReportsItsConfigurationError() async {
        let failure = await APIKeyCredentialWriter(settings: settings).validationFailure(of: "not-json", for: "alibaba")
        XCTAssertEqual(failure, AlibabaSpeechError.configuration.localizedDescription)
    }

    func testValidationFailure_azureShowsAFixedLineRatherThanTheProviderError() async {
        let failure = await APIKeyCredentialWriter(settings: settings).validationFailure(
            of: "secret-key:not a region!", for: "azure"
        )
        XCTAssertEqual(
            failure, "✗ Azure Speech: the key and region could not be verified, so they were not saved."
        )
        XCTAssertFalse(failure?.contains("secret-key") ?? true)
    }

    func testSavedMessage_wordsEachProviderAsBefore() {
        XCTAssertEqual(
            APIKeyCredentialWriter.savedMessage(for: "deepgram", title: "Deepgram"),
            "✓ Deepgram key validated and saved"
        )
        XCTAssertEqual(
            APIKeyCredentialWriter.savedMessage(for: "elevenlabs", title: "ElevenLabs"),
            "✓ ElevenLabs key validated and saved"
        )
        XCTAssertEqual(
            APIKeyCredentialWriter.savedMessage(for: "meta", title: "Meta"),
            "✓ Meta key validated for Muse Voice Transcribe and saved"
        )
        XCTAssertEqual(
            APIKeyCredentialWriter.savedMessage(for: "soniox", title: "Soniox"),
            "✓ Soniox key saved for transcription and voice output"
        )
        XCTAssertEqual(
            APIKeyCredentialWriter.savedMessage(for: "revai", title: "Rev.ai"), "✓ Rev.ai access token saved"
        )
        XCTAssertEqual(APIKeyCredentialWriter.savedMessage(for: "openai", title: "OpenAI"), "✓ OpenAI key saved")
        XCTAssertTrue(APIKeyCredentialWriter.savedMessage(for: "azure", title: "Azure Speech").hasPrefix("✓ Azure"))
        XCTAssertTrue(APIKeyCredentialWriter.savedMessage(for: "alibaba", title: "x").hasPrefix("✓ Alibaba"))
    }
}

final class APIKeyProviderPresentationTests: XCTestCase {
    func testKnownEntry_usesItsOwnTitleAndHelp() {
        let deepgram = APIKeyProviderPresentation(entryID: "deepgram")
        XCTAssertEqual(deepgram.title, "Deepgram")
        XCTAssertEqual(deepgram.systemImage, "waveform")
        XCTAssertEqual(deepgram.help, "Get your key from deepgram.com.")
        XCTAssertEqual(APIKeyProviderPresentation(entryID: "revai").help, "Get your access token from www.rev.ai.")
    }

    func testGoogleEntry_isTitledByTheGeminiProviderName() {
        XCTAssertEqual(
            APIKeyProviderPresentation(entryID: "google").title, GeminiTranscribeModels.providerDisplayName
        )
    }

    func testFileSpeechProviders_describeThemselvesFromTheirMetadata() {
        for provider in FileSpeechProvider.allCases {
            let presentation = APIKeyProviderPresentation(entryID: provider.rawValue)
            XCTAssertEqual(presentation.title, provider.metadata.displayName)
            XCTAssertEqual(presentation.systemImage, provider.metadata.systemImage)
            XCTAssertEqual(
                presentation.help,
                "Get your key from \(provider.metadata.website). Access is checked when transcribing."
            )
        }
    }

    func testUnknownEntry_isTheGladiaCard() {
        let gladia = APIKeyProviderPresentation(entryID: "gladia")
        XCTAssertEqual(gladia.title, "Gladia")
        XCTAssertEqual(gladia.help, "Get your key from gladia.io.")
        XCTAssertEqual(APIKeyProviderPresentation(entryID: "some-future-provider"), gladia)
    }
}

private struct WriterDeniedKeychainAccess: KeychainPermissionsChecking {
    func ensureKeychainAccess(forService: String) async -> Bool { false }
}
#endif
