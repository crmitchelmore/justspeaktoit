import XCTest
@testable import SpeakCore

final class ModelCredentialResolverTests: XCTestCase {
    func testLiveProvider_UsesProviderCredential() {
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: "deepgram/nova-3-streaming",
                purpose: .liveTranscription
            ),
            .apiKey(identifier: "deepgram.apiKey", providerName: "Deepgram")
        )
    }

    func testAppleAndLocalModels_DoNotRequireCredential() {
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: AppleLocalModels.preferredSpeechModelID,
                purpose: .liveTranscription
            ),
            .notRequired
        )
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: "local/post-processing/rules",
                purpose: .postProcessing
            ),
            .notRequired
        )
    }

    func testBatchModels_DistinguishOpenAIFromOpenRouter() {
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: "openai/gpt-4o-transcribe",
                purpose: .batchTranscription
            ),
            .apiKey(identifier: "openai.apiKey", providerName: "OpenAI")
        )
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: "openai/gpt-4o-audio-preview-2024-12-17",
                purpose: .batchTranscription
            ),
            .apiKey(identifier: "openrouter.apiKey", providerName: "OpenRouter")
        )
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: "google/gemini-2.0-flash-001",
                purpose: .batchTranscription
            ),
            .apiKey(identifier: "openrouter.apiKey", providerName: "OpenRouter")
        )
    }

    func testPostProcessingRemoteModels_UseOpenRouterCredential() {
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: "openai/gpt-5-mini",
                purpose: .postProcessing
            ),
            .apiKey(identifier: "openrouter.apiKey", providerName: "OpenRouter")
        )
    }

    func testVoiceProviders_UsePurposeSpecificCredentials() {
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: "openai/alloy",
                purpose: .voiceOutput
            ),
            .apiKey(identifier: "openai.tts.apiKey", providerName: "OpenAI")
        )
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: "aura-2",
                purpose: .voiceOutput
            ),
            .apiKey(identifier: "deepgram.apiKey", providerName: "Deepgram")
        )
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: "system/default",
                purpose: .voiceOutput
            ),
            .notRequired
        )
    }

    func testAvailability_ReflectsStoredIdentifierChanges() {
        XCTAssertEqual(
            ModelCredentialResolver.availability(
                for: "deepgram/nova-3-streaming",
                purpose: .liveTranscription,
                storedAPIKeyIdentifiers: []
            ),
            .missing(providerName: "Deepgram")
        )
        XCTAssertEqual(
            ModelCredentialResolver.availability(
                for: "deepgram/nova-3-streaming",
                purpose: .liveTranscription,
                storedAPIKeyIdentifiers: ["deepgram.apiKey"]
            ),
            .ready(providerName: "Deepgram")
        )
    }
}
