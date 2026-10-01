import XCTest
@testable import SpeakApp
import SpeakCore

final class AzureProviderRoutingTests: XCTestCase {
    func testAzureBatchUsesExistingSpeechCredential() async throws {
        let provider = await TranscriptionProviderRegistry.shared.provider(forModel: AzureTranscriptionModels.mai2)
        XCTAssertEqual(provider?.metadata.apiKeyIdentifier, "azure.speech.apiKey")
        XCTAssertEqual(Set(provider?.supportedModels().map(\.id) ?? []), AzureTranscriptionModels.batchIDs)
    }

    func testAzureVoiceCardIsSharedAndMAICostIsNotNeuralEstimate() {
        XCTAssertTrue(TTSProvider.azure.sharesTranscriptionCredential)
        XCTAssertNil(TTSProvider.azure.estimatedCost(
            characterCount: 1000, quality: .high, voiceID: "azure/en-US-Harper:MAI-Voice-2"
        ))
        XCTAssertNotNil(TTSProvider.azure.estimatedCost(
            characterCount: 1000, quality: .high, voiceID: "azure/en-GB-SoniaNeural"
        ))
    }

    func testMAIVoice21Estimates_useThePublishedPerModelRates() {
        XCTAssertEqual(TTSProvider.azure.estimatedCost(
            characterCount: 1000, quality: .standard, voiceID: "azure/en-US-Harper:MAI-Voice-2.1"
        ), Decimal(string: "0.022"))
        XCTAssertEqual(TTSProvider.azure.estimatedCost(
            characterCount: 1000, quality: .highest, voiceID: "azure/en-US-Harper:MAI-Voice-2.1-Flash"
        ), Decimal(string: "0.015"))
    }

    func testPickerCatalogue_projectsEveryCanonicalMAIVoiceOnce() {
        let canonical = AzureMAIVoiceCatalog.voices.map(\.id)
        XCTAssertEqual(VoiceCatalog.azureMAIVoices.map(\.id), canonical)
        let azure = VoiceCatalog.voices(for: .azure).map(\.id)
        let all = VoiceCatalog.allVoices.map(\.id)
        XCTAssertEqual(Set(all).count, all.count, "voice identifiers must be unique")
        for id in canonical {
            XCTAssertTrue(azure.contains(id), id)
            XCTAssertTrue(all.contains(id), id)
            XCTAssertEqual(TTSProvider.from(voiceID: id), .azure)
            XCTAssertEqual(VoiceCatalog.voice(forID: id)?.provider, .azure)
        }
        // The conventional neural voices remain the offline fallback too.
        XCTAssertTrue(azure.contains("azure/en-GB-SoniaNeural"))
    }

    func testFlashVoices_areMarkedLowLatency() throws {
        let flash = try XCTUnwrap(VoiceCatalog.voice(forID: "azure/en-GB-Emily:MAI-Voice-2.1-Flash"))
        let full = try XCTUnwrap(VoiceCatalog.voice(forID: "azure/en-GB-Emily:MAI-Voice-2.1"))
        XCTAssertEqual(flash.name, "Emily (en-GB, MAI-Voice-2.1-Flash)")
        XCTAssertTrue(flash.traits.contains(.lowLatency))
        XCTAssertTrue(flash.traits.contains(.british))
        XCTAssertFalse(full.traits.contains(.lowLatency))
    }

    func testListedOnlyMAIVoice_keepsAFriendlyNameOffline() throws {
        // A resource listing can offer locales the curated catalogue does not;
        // a saved choice must not fall back to a raw identifier.
        let voice = try XCTUnwrap(VoiceCatalog.voice(forID: "azure/fr-FR-Soleil:MAI-Voice-2.1"))
        XCTAssertEqual(voice.provider, .azure)
        XCTAssertEqual(voice.name, "Soleil (fr-FR, MAI-Voice-2.1)")
        XCTAssertNil(VoiceCatalog.voice(forID: "azure/en-GB-LibbyNeural"))
        let scripted = try XCTUnwrap(VoiceCatalog.voice(forID: "azure/zh-Hans-CN-Xiaoxiao:MAI-Voice-2.1"))
        XCTAssertEqual(scripted.name, "Xiaoxiao (zh-Hans-CN, MAI-Voice-2.1)")
    }

    func testListedCuratedVoice_keepsTheCatalogueTraits() throws {
        let listing = try JSONDecoder().decode([AzureSpeechVoice].self, from: Data(#"""
        [
          {"ShortName":"en-GB-Emily:MAI-Voice-2.1-Flash","DisplayName":"Emily","Locale":"en-GB","Gender":"Female"},
          {"ShortName":"fr-FR-Soleil:MAI-Voice-2.1","DisplayName":"Soleil","Locale":"fr-FR","Gender":"Female"}
        ]
        """#.utf8))
        let voices = listing.map(VoiceCatalog.azureListedVoice)
        let curated = try XCTUnwrap(VoiceCatalog.voice(forID: "azure/en-GB-Emily:MAI-Voice-2.1-Flash"))

        XCTAssertEqual(voices[0].traits, curated.traits)
        XCTAssertTrue(voices[0].traits.contains(.lowLatency))
        XCTAssertEqual(voices[0].name, "Emily (en-GB, MAI-Voice-2.1-Flash)")
        // A voice only the listing knows keeps the listing's own gender.
        XCTAssertEqual(voices[1].traits, [.female])
    }

    func testMAIAccessMessage_isReservedForAnUnavailableVoice() {
        let maiVoice = "azure/en-US-Harper:MAI-Voice-2.1"
        let unavailable = AzureSpeechSynthesisError(
            statusCode: 400, body: Data("Voice en-US-Harper:MAI-Voice-2.1 is not supported.".utf8), apiKey: ""
        )
        guard case .providerAccessRequired(.azure, let reason) = AzureSpeechClient.ttsError(
            for: unavailable, voice: maiVoice
        ) else { return XCTFail("An unavailable MAI voice should report an access requirement") }
        XCTAssertTrue(reason.contains("is not supported"))

        let malformed = AzureSpeechSynthesisError(
            statusCode: 400, body: Data("SSML parsing error: unexpected element".utf8), apiKey: ""
        )
        guard case .synthesisFailure(let message) = AzureSpeechClient.ttsError(for: malformed, voice: maiVoice)
        else { return XCTFail("A malformed MAI request is a request failure, not an access problem") }
        XCTAssertEqual(message, "Azure Speech returned HTTP 400. SSML parsing error: unexpected element")

        // A neural voice never gets MAI guidance, whatever Azure says.
        guard case .synthesisFailure = AzureSpeechClient.ttsError(
            for: unavailable, voice: "azure/en-GB-SoniaNeural"
        ) else { return XCTFail("Neural voices keep the general diagnostic") }
    }
}
