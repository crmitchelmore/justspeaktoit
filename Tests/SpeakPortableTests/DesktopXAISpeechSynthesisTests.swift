import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopXAISpeechSynthesisTests: DeepgramSpeechStubTestCase {
    func testPresets_ExecuteCanonicalRESTWAVSpeedAndRealUsage() async throws {
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        for (index, preset) in XAITTSCatalog.voices.enumerated() {
            let voice = DesktopSpeechVoice.xai(preset)
            let speed = index == 0 ? XAITTSAPI.speedRange.lowerBound : XAITTSAPI.speedRange.upperBound
            let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic xAI input.")
            let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: UUID())
            let wav = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, voice: voice, options: VoiceSynthesisOptions(speed: speed))
            }
            XCTAssertEqual(wav, audio)
            XCTAssertEqual(voice.apiKeyIdentifier, "xai.apiKey")
            XCTAssertEqual(voice.capabilities.nativeFlags, 1)
            XCTAssertEqual(voice.capabilities.speedRange, XAITTSAPI.speedRange)
            XCTAssertEqual(VoiceSynthesisPricing.estimate(for: voice, characterCount: 1_000_000), Decimal(15))
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: voice.modelID, voiceID: voice.id), voice)
            let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
            XCTAssertEqual(request.url, XAITTSAPI.speechEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
            XCTAssertEqual(body["text"] as? String, source.text)
            XCTAssertEqual(body["voice_id"] as? String, preset.id)
            XCTAssertEqual(body["language"] as? String, XAITTSCatalog.languageTag(for: nil))
            XCTAssertEqual(body["speed"] as? Double, speed)
            XCTAssertNil(body["model"])
            let format = try XCTUnwrap(body["output_format"] as? [String: Any])
            XCTAssertEqual(format["codec"] as? String, "wav")
            XCTAssertEqual(format["sample_rate"] as? Int, XAITTSAPI.defaultSampleRate)
            XCTAssertNil(format["bit_rate"])
            XCTAssertEqual(capture.records.count, 1)
            XCTAssertEqual(capture.records.first?.outcome, .completed)
            XCTAssertEqual(capture.records.first?.inputCharacters, source.text.unicodeScalars.count)
            XCTAssertEqual(capture.records.first?.audioDuration, Double(pcm.count) / 48_000)
            XCTAssertNil(capture.records.first?.historyRecordID)
        }
    }

    func testLongText_JoinsRealSegmentsWithOneCredentialAndHistoryAttribution() async throws {
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let owner = UUID()
        let source = try VoiceOutputSourceSnapshot(source: .history,
            text: String(repeating: "Synthetic long text. ", count: 900), recordID: owner)
        let probe = CredentialProbe()
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .history, historyRecordID: owner)
        let wav = try await VoiceSynthesisUsage.$capture.withValue(capture) {
            try await self.synthesize(source, credential: { try await probe.supply() })
        }
        let segments = TTSTextChunker.chunks(source.text, maximumCharacters: XAITTSAPI.maximumTextCharacters)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, segments.count)
        XCTAssertEqual(wav, DeepgramSpeechFixture.canonicalWAV(pcm:
            Data((0..<segments.count).flatMap { _ in Array(pcm) })))
        XCTAssertEqual(capture.records.map(\.inputCharacters), segments.map { $0.unicodeScalars.count })
        XCTAssertTrue(capture.records.allSatisfy { $0.historyRecordID == owner })
    }

    func testUnavailableRoutesAndControls_RefuseBeforeCredentialsWithoutFallback() async throws {
        for (model, voice) in [
            ("xai", "xai/unknown"), ("xai/invented", "xai/eve"), ("azure/neural", "xai/eve"),
            ("xai", "deepgram/aura-2-thalia-en")
        ] {
            XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: model, voiceID: voice))
        }
        let probe = CredentialProbe()
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic refusal.")
        for options in [
            try VoiceSynthesisOptions(speed: 0.5), try VoiceSynthesisOptions(speed: 2),
            try VoiceSynthesisOptions(pitch: 1), try VoiceSynthesisOptions(useSSML: true)
        ] {
            do {
                _ = try await synthesize(source, options: options, credential: { try await probe.supply() })
                XCTFail("Unsupported xAI controls were ignored")
            } catch { XCTAssertTrue(error is VoiceSynthesisConfigurationError) }
        }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testFailures_CancelledOrInvalidAudioNeverPublishPartialResultsOrEchoBodies() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .textFile, text: "Synthetic failure.")
        for status in [401, 402, 404, 429, 503] {
            StubURLProtocol.handler = {
                .respond(DeepgramSpeechFixture.response($0, status: status), Data("private provider body".utf8))
            }
            do {
                _ = try await synthesize(source)
                XCTFail("Failed xAI response returned audio")
            } catch {
                XCTAssertEqual(error as? DesktopXAISpeechError, .service(status))
                XCTAssertFalse(error.localizedDescription.contains("private provider body"))
            }
        }
        for audio in [
            Data("invalid audio".utf8), DeepgramSpeechFixture.canonicalWAV(pcm: Data()),
            try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000))
        ] {
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
            do {
                _ = try await synthesize(source)
                XCTFail("Invalid xAI audio returned a result")
            } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio) }
        }
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .textFile, historyRecordID: nil)
        StubURLProtocol.handler = { _ in .fail(URLError(.cancelled)) }
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
            XCTFail("Cancelled xAI synthesis returned audio")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(capture.records.first?.outcome, .cancelled)
        XCTAssertNil(capture.records.first?.audioDuration)
    }

    func testMissingKeyAndUnlistedVoice_RefuseBeforeTransportOrUsage() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic admission.")
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, credential: { "" })
            }
            XCTFail("Missing key admitted synthesis")
        } catch { XCTAssertEqual(error as? DesktopXAISpeechError, .missingCredential) }
        let probe = CredentialProbe()
        do {
            _ = try await synthesize(source, voice: .xai(XAITTSVoice(id: "synthetic-unlisted", name: "Unavailable")),
                credential: { try await probe.supply() })
            XCTFail("Unlisted voice admitted synthesis")
        } catch { XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedVoice) }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(capture.records.isEmpty)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testOversizedResponseAndLaterSegmentFailure_NeverReturnPartialAudio() async throws {
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                httpVersion: nil, headerFields: [
                    "Content-Length": String(DeepgramSpeechSynthesizer.defaultResponseLimit + 1)
                ])), audio)
        }
        let short = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic size limit.")
        do {
            _ = try await synthesize(short)
            XCTFail("Oversized response admitted audio")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .audioTooLarge) }
        let source = try VoiceOutputSourceSnapshot(source: .typedText,
            text: String(repeating: "Synthetic segmented input. ", count: 700))
        let segments = TTSTextChunker.chunks(source.text, maximumCharacters: XAITTSAPI.maximumTextCharacters)
        let first = try XCTUnwrap(segments.first)
        XCTAssertGreaterThan(segments.count, 1)
        StubURLProtocol.handler = { request in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
            return body["text"] as? String == first
                ? .respond(DeepgramSpeechFixture.response(request), audio)
                : .respond(DeepgramSpeechFixture.response(request, status: 503), Data("private failure".utf8))
        }
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .typedText, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
            XCTFail("Later segment failure returned partial audio")
        } catch { XCTAssertEqual(error as? DesktopXAISpeechError, .service(503)) }
        XCTAssertEqual(capture.records.map(\.outcome), [.completed, .failed])
        XCTAssertNotNil(capture.records.first?.audioDuration)
        XCTAssertNil(capture.records.last?.audioDuration)
    }

    private func synthesize(
        _ source: VoiceOutputSourceSnapshot,
        voice: DesktopSpeechVoice = .xai(XAITTSCatalog.voices[0]),
        options: VoiceSynthesisOptions? = nil,
        credential: @Sendable () async throws -> String = { "synthetic-key" }
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: voice, options: options ?? VoiceSynthesisOptions(), credential: credential)
    }
}
