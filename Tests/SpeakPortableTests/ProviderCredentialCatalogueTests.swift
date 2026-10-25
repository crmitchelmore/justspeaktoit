import XCTest
@testable import SpeakCore

final class ProviderCredentialCatalogueTests: XCTestCase {
    func testKnownCredentialsPreservePersistedIdentitiesAndAreUnique() {
        let expected: Set<String> = [
            "alibaba.apiKey", "assemblyai.apiKey", "azure.speech.apiKey", "cartesia.apiKey",
            "deepgram.apiKey", "elevenlabs.apiKey", "gladia.apiKey", "google.apiKey", "groq.apiKey",
            "meta.apiKey", "mistral.apiKey", "modulate.apiKey", "openai.apiKey", "openai.tts.apiKey",
            "openrouter.apiKey", "reson8.apiKey", "revai.apiKey", "smallest.apiKey", "soniox.apiKey",
            "speechmatics.apiKey", "stepfun.apiKey", "xai.apiKey"
        ]
        XCTAssertTrue(expected.isSubset(of: Set(ProviderCredentialCatalogue.all)))
        XCTAssertEqual(Set(ProviderCredentialCatalogue.all).count, ProviderCredentialCatalogue.all.count)
        XCTAssertEqual(ProviderCredentialCatalogue.all, ProviderCredentialCatalogue.all.sorted())
        XCTAssertEqual(Set(ProviderCredentialCatalogue.all), ModelCredentialResolver.allKnownAPIKeyIdentifiers)
    }

    func testEveryLiveAndFileProviderUsesTheCatalogueIncludingAzureException() {
        for provider in LiveTranscriptionProviderID.allCases where provider != .apple {
            let identifier = ProviderCredentialCatalogue.apiKeyIdentifier(for: provider.rawValue)
            XCTAssertEqual(provider.apiKeyIdentifier, identifier)
            XCTAssertTrue(ProviderCredentialCatalogue.all.contains(identifier))
        }
        XCTAssertNil(LiveTranscriptionProviderID.apple.apiKeyIdentifier)
        for provider in FileSpeechProvider.allCases {
            XCTAssertTrue(ProviderCredentialCatalogue.all.contains(provider.metadata.apiKeyIdentifier))
        }
        XCTAssertEqual(ProviderCredentialCatalogue.apiKeyIdentifier(for: "azure"), "azure.speech.apiKey")
        XCTAssertEqual(
            TranscriptionProviderMetadata(id: "azure", displayName: "Azure").apiKeyIdentifier,
            AzureSpeechConfiguration.credentialIdentifier
        )
        XCTAssertEqual(ProviderCredentialCatalogue.apiKeyIdentifier(for: "future"), "future.apiKey")
    }

    func testSyncCoveragePreservesExactExistingAllowlist() {
        let expected: Set<String> = [
            "alibaba.apiKey", "deepgram.apiKey", "openai.apiKey", "openrouter.apiKey", "elevenlabs.apiKey",
            "cartesia.apiKey", "assemblyai.apiKey", "gladia.apiKey", "google.apiKey", "modulate.apiKey",
            "soniox.apiKey", "xai.apiKey", "meta.apiKey"
        ]
        XCTAssertEqual(ProviderCredentialCatalogue.cloudKitSyncable, expected)
        XCTAssertTrue(expected.isSubset(of: Set(ProviderCredentialCatalogue.all)))
        XCTAssertFalse(ProviderCredentialCatalogue.cloudKitSyncable.contains("azure.speech.apiKey"))
        XCTAssertFalse(ProviderCredentialCatalogue.cloudKitSyncable.contains("openai.tts.apiKey"))
    }
}
