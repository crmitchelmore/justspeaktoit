import Foundation
import XCTest
@testable import SpeakCore

/// Opt-in tests: run only with an explicitly supplied credential and fixture.
/// Ordinary CI neither reads Keychain nor makes billable provider calls.
final class AzureSpeechIntegrationTests: XCTestCase {
    func testConfiguredResource_transcribesSyntheticFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["JSTI_AZURE_TEST_CREDENTIAL"],
              let fixture = environment["JSTI_AZURE_TEST_WAV"] else {
            throw XCTSkip("Requires explicitly supplied Azure test credential and synthetic WAV.")
        }
        let result = try await AzureBatchTranscriptionClient().transcribeFile(
            at: URL(fileURLWithPath: fixture), credentials: key, endpoint: "",
            model: AzureTranscriptionModels.fast, language: "en-GB"
        )
        XCTAssertTrue(result.text.lowercased().contains("quick brown fox"))
        XCTAssertGreaterThan(result.duration, 0)
    }

    func testConfiguredResource_synthesizesExistingNeuralVoice() async throws {
        guard let key = ProcessInfo.processInfo.environment["JSTI_AZURE_TEST_CREDENTIAL"] else {
            throw XCTSkip("Requires explicitly supplied Azure test credential.")
        }
        let request = try AzureSpeechVoiceAPI.synthesisRequest(
            credentials: key, text: "Azure speech integration test.", voice: "azure/en-GB-SoniaNeural",
            format: "riff-24khz-16bit-mono-pcm"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertGreaterThan(data.count, 44)
    }
}
