import Foundation
import XCTest
@testable import SpeakCore

/// Opt-in tests: run only with an explicitly supplied credential and fixture.
/// Ordinary CI neither reads Keychain nor makes billable provider calls.
final class AzureSpeechIntegrationTests: XCTestCase {
    func testTrialResource_MAIRecordedTranscription() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JSTI_AZURE_TEST_EXTENDED"] == "1",
              let key = env["JSTI_AZURE_TEST_CREDENTIAL"],
              let fixture = env["JSTI_AZURE_TEST_WAV"],
              let endpoint = env["JSTI_AZURE_TEST_ENDPOINT"] else { throw XCTSkip("Requires trial test setup.") }
        for model in [AzureTranscriptionModels.mai2, AzureTranscriptionModels.mai15] {
            let result = try await AzureBatchTranscriptionClient().transcribeFile(
                at: URL(fileURLWithPath: fixture), credentials: key, endpoint: endpoint,
                model: model, language: "en-GB"
            )
            XCTAssertTrue(result.text.lowercased().contains("quick brown fox"), model)
        }
    }

    func testTrialResource_MAIVoice() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JSTI_AZURE_TEST_EXTENDED"] == "1",
              let key = env["JSTI_AZURE_TEST_CREDENTIAL"] else { throw XCTSkip("Requires trial test setup.") }
        let voices = try await AzureSpeechVoiceAPI().listVoices(credentials: key)
        guard let voice = voices.first(where: { $0.id.contains(":MAI-Voice-2") }) else {
            XCTFail("Resource returned no MAI-Voice-2 voices."); return
        }
        let request = try AzureSpeechVoiceAPI.synthesisRequest(
            credentials: key, text: "Azure trial voice test.", voice: voice.id,
            format: "riff-24khz-16bit-mono-pcm"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
    }

    func testTrialResource_liveTranscription() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JSTI_AZURE_TEST_EXTENDED"] == "1",
              let key = env["JSTI_AZURE_TEST_CREDENTIAL"],
              let endpoint = env["JSTI_AZURE_TEST_ENDPOINT"],
              let fixture = env["JSTI_AZURE_TEST_PCM"] else { throw XCTSkip("Requires trial test setup.") }
        let audio = try Data(contentsOf: URL(fileURLWithPath: fixture))
        for model in ["azure-speech", "mai-transcribe"] {
            let client = AzureVoiceLiveClient(credentials: key, endpoint: endpoint, model: model, language: "en-GB")
            client.start(onTranscript: { _, _ in }, onError: { error in
                XCTFail("Voice Live: \(error.localizedDescription)")
            })
            for offset in stride(from: 0, to: audio.count, by: 4_800) {
                client.sendAudio(audio.subdata(in: offset..<min(offset + 4_800, audio.count)))
                try await Task.sleep(for: .milliseconds(100))
            }
            let final = await client.finishAndWait()
            XCTAssertTrue(final?.lowercased().contains("quick brown fox") == true, model)
            XCTAssertTrue(final?.lowercased().contains("lazy dog") == true, "Trailing words: \(model)")
            client.stop()
        }
    }

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
