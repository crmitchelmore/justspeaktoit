import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopSpeechSynthesisTests: DeepgramSpeechStubTestCase {
    func testAzureNeural_ExecutesProsodyAndProducesExactLosslessAudio() async throws {
        let audio = fixtureWAV
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic A & B.")
        let options = try VoiceSynthesisOptions(speed: 1.5, pitch: -3)
        let wav = try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: .azureNeural(AzureNeuralVoiceCatalog.voices[0]), options: options
        ) { "synthetic-key:eastus" }
        XCTAssertEqual(wav, fixtureWAV)
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        let body = try XCTUnwrap(String(bytes: XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("rate='+50%' pitch='-3st'"), body)
        XCTAssertTrue(body.contains("Synthetic A &amp; B."), body)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Microsoft-OutputFormat"), "riff-24khz-16bit-mono-pcm")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "synthetic-key")
        XCTAssertEqual(request.url?.host, "eastus.tts.speech.microsoft.com")
    }

    func testAzureNeural_LongPlainTextJoinsSegmentsAndReadsOneCredential() async throws {
        let audio = fixtureWAV
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let source = try VoiceOutputSourceSnapshot(source: .clipboard,
            text: String(repeating: "Synthetic text sentence. ", count: 180))
        let probe = CredentialProbe()
        let wav = try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: .azureNeural(AzureNeuralVoiceCatalog.voices[1]), options: VoiceSynthesisOptions()
        ) { _ = try await probe.supply(); return "synthetic-key:uksouth" }
        let count = SpeechTextSegmenter.segments(source.text).count
        XCTAssertGreaterThan(count, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, count)
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(wav, DeepgramSpeechFixture.canonicalWAV(pcm: Data((0..<count).flatMap { _ in Array(pcm) })))
    }

    func testUnsupportedControlsAndFullDocumentProsody_RefuseBeforeCredential() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic source.")
        let probe = CredentialProbe()
        do {
            _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                source, voice: .deepgram(DeepgramSpeechCatalog.voices[0]),
                options: VoiceSynthesisOptions(speed: 1.2)
            ) { try await probe.supply() }
            XCTFail("Unsupported controls were ignored")
        } catch { XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedControls) }
        let document = try VoiceOutputSourceSnapshot(source: .typedText, text: "<speak>Synthetic text.</speak>")
        do {
            _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                document, voice: .azureNeural(AzureNeuralVoiceCatalog.voices[0]),
                options: VoiceSynthesisOptions(speed: 1.2, useSSML: true)
            ) { try await probe.supply() }
            XCTFail("Document controls were silently dropped")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .documentControls) }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testSSMLFragment_IsNeverSplitAcrossTags() async throws {
        let audio = fixtureWAV
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let fragment = "<emphasis>" + String(repeating: "Synthetic sentence. ", count: 160) + "</emphasis>"
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: fragment)
        _ = try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: .azureNeural(AzureNeuralVoiceCatalog.voices[0]),
            options: VoiceSynthesisOptions(pitch: 2, useSSML: true)
        ) { "synthetic-key:eastus" }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        let body = try XCTUnwrap(String(bytes: XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains(fragment), body)
        XCTAssertTrue(body.contains("pitch='+2st'"), body)
    }

    func testInvalidControlCodecAndUnsupportedProvider_NeverMigrateToDeepgram() throws {
        let defaults = try VoiceSynthesisOptions()
        XCTAssertEqual(defaults.speed, VoiceSynthesisOptions.defaultSpeed)
        XCTAssertEqual(defaults.pitch, VoiceSynthesisOptions.defaultPitch)
        XCTAssertEqual(defaults.useSSML, VoiceSynthesisOptions.defaultUseSSML)
        XCTAssertNoThrow(try VoiceSynthesisOptions(speed: VoiceSynthesisOptions.speedRange.lowerBound,
            pitch: VoiceSynthesisOptions.pitchRange.lowerBound))
        XCTAssertNoThrow(try VoiceSynthesisOptions(speed: VoiceSynthesisOptions.speedRange.upperBound,
            pitch: VoiceSynthesisOptions.pitchRange.upperBound))
        for speed in [Double.nan, .infinity, 0.49, 2.01] {
            XCTAssertThrowsError(try VoiceSynthesisOptions(speed: speed))
        }
        for pitch in [Double.nan, 1.2, -13, 13] {
            XCTAssertThrowsError(try VoiceSynthesisOptions(pitch: pitch))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(VoiceSynthesisOptions.self,
            from: Data(#"{"speed":4,"pitch":0,"useSSML":false}"#.utf8)))
        XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: nil, voiceID: "system/Alex"))
        XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: nil, voiceID: "azure/unknown"))
        XCTAssertThrowsError(try DesktopSpeechVoice.resolved(
            modelID: nil, voiceID: AzureMAIVoiceCatalog.voices[0].id
        ))
        XCTAssertEqual(DesktopSpeechVoice.voices.count,
                       DeepgramSpeechCatalog.voices.count + AzureNeuralVoiceCatalog.voices.count)
        XCTAssertEqual(Set(DesktopSpeechVoice.voices.map(\.id)).count, DesktopSpeechVoice.voices.count)
        for voice in AzureNeuralVoiceCatalog.voices {
            XCTAssertEqual(
                try DesktopSpeechVoice.resolved(modelID: "azure/neural", voiceID: voice.id), .azureNeural(voice)
            )
        }
    }

    private var fixtureWAV: Data { DeepgramSpeechFixture.canonicalWAV(pcm: pcm) }
}
