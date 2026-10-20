import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopCartesiaSpeechSynthesisTests: DeepgramSpeechStubTestCase {
    func testCanonicalPresets_ExecuteSharedRequestControlsAndMeasuredUsage() async throws {
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        for (index, preset) in CartesiaTTSCatalog.voices.enumerated() {
            let voice = DesktopSpeechVoice.cartesia(preset)
            let speed = index.isMultiple(of: 2)
                ? CartesiaTTSAPI.speedRange.lowerBound : CartesiaTTSAPI.speedRange.upperBound
            let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic cafe\u{301} input.")
            let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .clipboard, historyRecordID: UUID())
            let wav = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, voice: voice, options: VoiceSynthesisOptions(speed: speed))
            }
            XCTAssertEqual(wav, audio)
            XCTAssertEqual(voice.apiKeyIdentifier, CartesiaTTSCatalog.credentialIdentifier)
            XCTAssertEqual(voice.capabilities.nativeFlags, 1)
            XCTAssertEqual(voice.capabilities.speedRange, CartesiaTTSAPI.speedRange)
            XCTAssertEqual(VoiceSynthesisPricing.estimate(for: voice, characterCount: 1_000),
                           CartesiaTTSAPI.estimatedCostPerThousandCharacters)
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: voice.modelID, voiceID: voice.id), voice)
            let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
            XCTAssertEqual(request.url, CartesiaTTSAPI.bytesEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: CartesiaTTSAPI.versionHeaderField),
                           CartesiaTTSAPI.apiVersion)
            let body = try jsonBody(request)
            let expected = CartesiaTTSRequest(voiceID: voice.id, outputFormat: .wav(sampleRate: 24_000),
                languageIdentifier: nil, content: source.text, speed: speed)
            let submitted = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
            let canonical = try JSONSerialization.data(
                withJSONObject: expected.jsonBody(transcript: source.text), options: .sortedKeys)
            XCTAssertEqual(submitted, canonical)
            XCTAssertEqual(capture.records.first?.outcome, .completed)
            XCTAssertEqual(capture.records.first?.inputCharacters, source.text.unicodeScalars.count)
            XCTAssertEqual(capture.records.first?.audioDuration, Double(pcm.count) / 48_000)
            XCTAssertNil(capture.records.first?.historyRecordID)
        }
    }

    func testLongText_UsesCanonicalChunkerOneCredentialAndRealHistoryAttribution() async throws {
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let owner = UUID()
        let source = try VoiceOutputSourceSnapshot(source: .history,
            text: String(repeating: "Synthetic long text. ", count: 400), recordID: owner)
        let probe = CredentialProbe()
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .history, historyRecordID: owner)
        let wav = try await VoiceSynthesisUsage.$capture.withValue(capture) {
            try await self.synthesize(source, credential: { try await probe.supply() })
        }
        let segments = TTSTextChunker.chunks(source.text)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, segments.count)
        let submitted = try StubURLProtocol.recordedRequests.map {
            try XCTUnwrap(jsonBody($0)["transcript"] as? String)
        }
        XCTAssertEqual(submitted, segments)
        XCTAssertEqual(submitted.joined(), source.text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(wav, DeepgramSpeechFixture.canonicalWAV(pcm:
            Data((0..<segments.count).flatMap { _ in Array(pcm) })))
        XCTAssertEqual(capture.records.map(\.inputCharacters), segments.map { $0.unicodeScalars.count })
        XCTAssertTrue(capture.records.allSatisfy { $0.historyRecordID == owner })
    }

    func testUnavailableModelsVoicesAndControls_RefuseBeforeCredentialsWithoutFallback() async throws {
        let voice = DesktopSpeechVoice.cartesia(CartesiaTTSCatalog.defaultVoice)
        let models = [
            nil, CartesiaTTSCatalog.providerIdentifier, CartesiaTTSCatalog.defaultModel.rawValue, voice.modelID
        ]
        for model in models {
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: model, voiceID: voice.id), voice)
        }
        for (model, identifier) in [
            (voice.modelID, "cartesia/unknown"), ("cartesia/sonic-3", voice.id), ("sonic-3.5", voice.id),
            ("azure/neural", voice.id), (voice.modelID, "xai/eve")
        ] {
            XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: model, voiceID: identifier))
        }
        let probe = CredentialProbe()
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic refusal.")
        for options in [
            try VoiceSynthesisOptions(speed: 0.5), try VoiceSynthesisOptions(speed: 2),
            try VoiceSynthesisOptions(pitch: 1), try VoiceSynthesisOptions(useSSML: true)
        ] {
            do {
                _ = try await synthesize(source, options: options, credential: { try await probe.supply() })
                XCTFail("Unsupported Cartesia controls were ignored")
            } catch { XCTAssertTrue(error is VoiceSynthesisConfigurationError) }
        }
        let unknown = CartesiaTTSVoice(id: "unknown", name: "Unavailable", gender: .female, accent: .american)
        do {
            _ = try await synthesize(source, voice: .cartesia(unknown), credential: { try await probe.supply() })
            XCTFail("Unlisted Cartesia voice was admitted")
        } catch { XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedVoice) }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testServiceAndAudioFailures_NeverEchoBodiesOrPublishInvalidResults() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .textFile, text: "Synthetic failure.")
        for status in [401, 403, 402, 404, 429, 503] {
            StubURLProtocol.handler = {
                .respond(DeepgramSpeechFixture.response($0, status: status), Data("private provider body".utf8))
            }
            do {
                _ = try await synthesize(source)
                XCTFail("Failed Cartesia response returned audio")
            } catch {
                XCTAssertEqual(error as? DesktopCartesiaSpeechError, .service(status))
                XCTAssertFalse(error.localizedDescription.contains("private provider body"))
            }
        }
        for audio in [
            Data("invalid".utf8), DeepgramSpeechFixture.canonicalWAV(pcm: Data()),
            DeepgramSpeechFixture.canonicalWAV(pcm: Data(repeating: 0, count: 480)),
            try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000)),
            Data(DeepgramSpeechFixture.canonicalWAV(pcm: pcm).dropLast())
        ] {
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
            do {
                _ = try await synthesize(source)
                XCTFail("Invalid Cartesia audio returned a result")
            } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio) }
        }
    }

    func testMissingKeyAndCancellation_NoFalseCompletionOrMeasuredDuration() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic cancellation.")
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .typedText, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, credential: { "" })
            }
            XCTFail("Missing key admitted synthesis")
        } catch { XCTAssertEqual(error as? DesktopCartesiaSpeechError, .missingCredential) }
        XCTAssertTrue(capture.records.isEmpty)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        StubURLProtocol.handler = { _ in .fail(URLError(.cancelled)) }
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
            XCTFail("Cancelled synthesis returned audio")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(capture.records.first?.outcome, .cancelled)
        XCTAssertNil(capture.records.first?.audioDuration)
    }

    func testOversizedAndLaterSegmentFailure_NeverReturnPartialAudio() async throws {
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                httpVersion: nil, headerFields: [
                    "Content-Length": String(DeepgramSpeechSynthesizer.defaultResponseLimit + 1)
                ])), audio)
        }
        let short = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic size bound.")
        do {
            _ = try await synthesize(short)
            XCTFail("Oversized response was admitted")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .audioTooLarge) }
        let source = try VoiceOutputSourceSnapshot(source: .typedText,
            text: String(repeating: "Synthetic segmented input. ", count: 300))
        let segments = TTSTextChunker.chunks(source.text)
        let first = try XCTUnwrap(segments.first)
        XCTAssertGreaterThan(segments.count, 1)
        StubURLProtocol.handler = { request in
            try self.jsonBody(request)["transcript"] as? String == first
                ? .respond(DeepgramSpeechFixture.response(request), audio)
                : .respond(DeepgramSpeechFixture.response(request, status: 503), Data("private failure".utf8))
        }
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .typedText, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
            XCTFail("Later failure published partial audio")
        } catch { XCTAssertEqual(error as? DesktopCartesiaSpeechError, .service(503)) }
        XCTAssertEqual(capture.records.map(\.outcome), [.completed, .failed])
        XCTAssertNotNil(capture.records.first?.audioDuration)
        XCTAssertNil(capture.records.last?.audioDuration)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }

    private func synthesize(
        _ source: VoiceOutputSourceSnapshot,
        voice: DesktopSpeechVoice = .cartesia(CartesiaTTSCatalog.defaultVoice),
        options: VoiceSynthesisOptions? = nil,
        credential: @Sendable () async throws -> String = { "synthetic-key" }
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: voice, options: options ?? VoiceSynthesisOptions(), credential: credential)
    }
}
