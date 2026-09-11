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
}
