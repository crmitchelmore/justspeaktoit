import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class AzureSSMLPreflightTests: DeepgramSpeechStubTestCase {
    func testFinalWrappedBody_Exact64KiBAcrossVoicesQualitiesUnicodeAndProsodyUsesRealRequest() async throws {
        for neural in AzureNeuralVoiceCatalog.voices {
            let voice = DesktopSpeechVoice.azureNeural(neural)
            for quality in VoiceSynthesisQuality.allCases {
                let options = try VoiceSynthesisOptions(speed: 1.5, pitch: -3, useSSML: true, quality: quality)
                let body = try AzureSpeechVoiceAPI.ssmlBody(
                    text: "x", voice: voice.id, speed: options.speed, pitch: options.pitch, useSSML: true)
                let capacity = DesktopSpeechSynthesis.maximumSSMLBytes - body.utf8.count + 1
                let text = String(repeating: "猫", count: capacity / 3) + String(repeating: "x", count: capacity % 3)
                let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: text)
                let rate = voice.sampleRate(quality: quality)
                let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: rate))
                StubURLProtocol.reset()
                StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), wav) }
                let probe = CredentialProbe()
                let actual = try await DesktopSpeechSynthesis(session: session).synthesize(
                    source, voice: voice, options: options
                ) { _ = try await probe.supply(); return "synthetic-key:eastus" }
                XCTAssertEqual(actual, wav)
                XCTAssertEqual(probe.count, 1)
                XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
                let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
                let bytes = StubURLProtocol.body(of: request)
                XCTAssertEqual(bytes.count, 65_536)
                XCTAssertEqual(bytes, Data(try AzureSpeechVoiceAPI.ssmlBody(
                    text: text, voice: voice.id, speed: options.speed, pitch: options.pitch, useSSML: true).utf8))
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Microsoft-OutputFormat"),
                               "riff-\(rate / 1000)khz-16bit-mono-pcm")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "synthetic-key")
                StubURLProtocol.reset()
                let over = try VoiceOutputSourceSnapshot(source: .clipboard, text: text + "x")
                do {
                    _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                        over, voice: voice, options: options
                    ) { _ = try await probe.supply(); return "synthetic-key:eastus" }
                    XCTFail("65,537-byte wrapped body was admitted")
                } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .ssmlTooLarge) }
                XCTAssertEqual(probe.count, 1)
                XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
            }
        }
    }

    func testCompleteDocument_BoundaryIsByteExactAndSliderRefusalStillPrecedesKey() async throws {
        let voice = DesktopSpeechVoice.azureNeural(AzureNeuralVoiceCatalog.voices[0])
        let shell = "<speak></speak>"
        let document = "<speak>" + String(repeating: "x", count: 65_536 - shell.utf8.count) + "</speak>"
        let probe = CredentialProbe()
        let wav = fixtureWAV
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), wav) }
        let source = try VoiceOutputSourceSnapshot(source: .textFile, text: document)
        let actual = try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: voice, options: .init(useSSML: true)
        ) { _ = try await probe.supply(); return "synthetic-key:uksouth" }
        XCTAssertEqual(actual, wav)
        XCTAssertEqual(StubURLProtocol.body(of: try XCTUnwrap(StubURLProtocol.recordedRequests.first)),
                       Data(document.utf8))
        XCTAssertEqual(probe.count, 1)
        StubURLProtocol.reset()
        for (text, speed, pitch, failure) in [
            (document + "x", 1.0, 0.0, DesktopSpeechSynthesisError.ssmlTooLarge),
            (document, 1.5, 0.0, DesktopSpeechSynthesisError.documentControls),
            (document + "x", 1.5, 0.0, DesktopSpeechSynthesisError.documentControls),
            (document + "x", 1.0, 2.0, DesktopSpeechSynthesisError.documentControls)
        ] {
            do {
                _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                    .init(source: .typedText, text: text), voice: voice,
                    options: .init(speed: speed, pitch: pitch, useSSML: true)
                ) { _ = try await probe.supply(); return "synthetic-key:eastus" }
                XCTFail("Invalid document reached credentials")
            } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, failure) }
        }
        XCTAssertEqual(probe.count, 1)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testPureBody_IsExactlyTransportBodyAcrossCredentialsAndPreservesMAIContract() throws {
        for voice in [DesktopSpeechVoice.azureNeural(AzureNeuralVoiceCatalog.voices[0]),
                      .azureMAI(AzureMAIVoiceCatalog.voices[0])] {
            for text in ["A & < B", "<phoneme alphabet='ipa' ph='x'>Token</phoneme>", "<speak>Token</speak>"] {
                for ssml in [false, true] {
                    let body = try AzureSpeechVoiceAPI.ssmlBody(text: text, voice: voice.id, useSSML: ssml)
                    for credential in ["synthetic-a:eastus", "synthetic-b:uksouth"] {
                        let request = try AzureSpeechVoiceAPI.synthesisRequest(
                            credentials: credential, text: text, voice: voice.id, format: "synthetic",
                            useSSML: ssml)
                        XCTAssertEqual(request.httpBody, Data(body.utf8))
                    }
                }
            }
        }
    }

    private var fixtureWAV: Data {
        DeepgramSpeechFixture.canonicalWAV(pcm: Data(repeating: 1, count: 480))
    }
}
