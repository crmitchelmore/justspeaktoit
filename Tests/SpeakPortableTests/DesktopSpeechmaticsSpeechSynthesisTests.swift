import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopSpeechmaticsSpeechSynthesisTests: DeepgramSpeechStubTestCase {
    func testCanonicalVoices_UseTheSharedMacRequestAndActualSixteenKilohertzUsage() async throws {
        let audio = try wave()
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        for preset in SpeechmaticsTTSCatalog.voices {
            let voice = DesktopSpeechVoice.speechmatics(preset)
            let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic cafe\u{301} input.")
            let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .clipboard, historyRecordID: UUID())
            let result = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, voice: voice)
            }
            XCTAssertEqual(result, audio)
            XCTAssertEqual(voice.sampleRate, 16_000)
            XCTAssertEqual(voice.apiKeyIdentifier, SpeechmaticsTTSCatalog.credentialIdentifier)
            XCTAssertEqual(voice.capabilities.nativeFlags, 0)
            XCTAssertTrue(voice.label.contains("English"))
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: voice.modelID, voiceID: voice.id), voice)
            let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
            XCTAssertEqual(request.url, SpeechmaticsTTSAPI.generateURL(
                request: SpeechmaticsTTSRequest(voiceID: voice.id)))
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                           ["Bearer", "synthetic-key"].joined(separator: " "))
            XCTAssertEqual(try jsonBody(request) as NSDictionary, ["text": source.text] as NSDictionary)
            let record = try XCTUnwrap(capture.records.first)
            XCTAssertEqual(record.outcome, .completed)
            XCTAssertEqual(record.inputCharacters, source.text.unicodeScalars.count)
            XCTAssertEqual(record.audioDuration, Double(pcm.count) / 32_000)
            XCTAssertNil(record.historyRecordID)
            XCTAssertNil(record.reportedInputTokens)
            XCTAssertNil(record.estimatedInputCostUSD)
            XCTAssertNil(record.estimatedAudioCostUSD)
            XCTAssertEqual(record.estimatedCostUSD,
                Decimal(source.text.count) * SpeechmaticsTTSAPI.estimatedCostPerThousandCharacters / 1_000)
        }
        XCTAssertEqual(SpeechmaticsTTSCatalog.voices.count, 4)
    }

    func testSegments_KeepOneKeyExactRateOneHeaderAndTheRealHistoryOwner() async throws {
        let audio = try wave()
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let source = try VoiceOutputSourceSnapshot(source: .history,
            text: String(repeating: "x", count: DeepgramSpeechRequest.maximumCharacters + 17), recordID: UUID())
        let probe = CredentialProbe()
        let capture = VoiceSynthesisUsage.Capture(
            operation: .export, source: .history, historyRecordID: source.recordID)
        let joined = try await VoiceSynthesisUsage.$capture.withValue(capture) {
            try await self.synthesize(source, credential: { try await probe.supply() })
        }
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
        XCTAssertEqual(joined, try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm + pcm, sampleRate: 16_000)))
        XCTAssertEqual(try VoiceGeneratedAudio(validating: joined, sampleRate: 16_000).duration,
                       Double(pcm.count) / 16_000, accuracy: 0.000001)
        XCTAssertTrue(capture.records.allSatisfy { $0.historyRecordID == source.recordID && $0.outcome == .completed })
        let submitted = try StubURLProtocol.recordedRequests.map { try XCTUnwrap(jsonBody($0)["text"] as? String) }
        XCTAssertEqual(submitted, SpeechTextSegmenter.segments(source.text))
    }

    func testStrictTupleAndUnsupportedOptions_RefuseBeforeCredentialsWithoutDefaultVoiceFallback() async throws {
        let voice = DesktopSpeechVoice.speechmatics(SpeechmaticsTTSCatalog.defaultVoice)
        for model in [nil, SpeechmaticsTTSCatalog.providerIdentifier] {
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: model, voiceID: voice.id), voice)
        }
        for (model, identifier) in [
            ("speechmatics", "speechmatics/unknown"), ("speechmatics/unknown", voice.id),
            ("speechmatics", "groq/unknown"), ("azure/neural", voice.id),
            ("speechmatics", "speechmatics/sarah/other")
        ] {
            XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: model, voiceID: identifier))
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic refusal.")
        let probe = CredentialProbe()
        for options in [
            try VoiceSynthesisOptions(speed: 1.25), try VoiceSynthesisOptions(pitch: 1),
            try VoiceSynthesisOptions(useSSML: true)
        ] {
            do {
                _ = try await synthesize(source, options: options, credential: { try await probe.supply() })
                XCTFail("Unsupported Speechmatics controls were ignored")
            } catch { XCTAssertTrue(error is VoiceSynthesisConfigurationError) }
        }
        let forged = SpeechmaticsTTSVoice(id: "sarah", name: "Unknown", gender: .female, accent: .british)
        do {
            _ = try await synthesize(source, voice: .speechmatics(forged), credential: { try await probe.supply() })
            XCTFail("A noncanonical tuple was admitted")
        } catch { XCTAssertTrue(error is VoiceSynthesisConfigurationError) }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testPricing_UsesOnlySubmittedGraphemesAndPreservesScalarObservations() throws {
        let voice = DesktopSpeechVoice.speechmatics(SpeechmaticsTTSCatalog.defaultVoice)
        let text = "  cafe\u{301}  \n "
        XCTAssertEqual(try VoiceSynthesisPricing.estimate(for: voice, text: text),
                       Decimal(4) * SpeechmaticsTTSAPI.estimatedCostPerThousandCharacters / 1_000)
        XCTAssertEqual(VoiceSynthesisPricing.ratePerThousandCharacters(for: voice), Decimal(string: "0.011"))
    }

    func testServiceFailures_AreSanitizedAndKeepNoFalseMeasuredAudioOrTokens() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic failure.")
        for (status, expected) in [
            (401, DesktopSpeechmaticsSpeechError.unauthorized), (403, .unauthorized),
            (402, .quotaExceeded), (429, .rateLimited), (503, .service(503))
        ] {
            StubURLProtocol.handler = {
                .respond(DeepgramSpeechFixture.response($0, status: status), Data("private provider body".utf8))
            }
            let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .typedText, historyRecordID: nil)
            do {
                _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
                XCTFail("Service failure returned audio")
            } catch {
                XCTAssertEqual(error as? DesktopSpeechmaticsSpeechError, expected)
                XCTAssertFalse(error.localizedDescription.contains("private provider body"))
            }
            XCTAssertEqual(capture.records.first?.outcome, .failed)
            XCTAssertNil(capture.records.first?.audioDuration)
            XCTAssertNil(capture.records.first?.reportedInputTokens)
        }
    }

    func testMalformedUnsupportedAndMixedRateAudio_NeverReturnPartialResults() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .textFile, text: "Synthetic invalid audio.")
        let audio = try wave()
        var stereo = audio
        stereo[22] = 2
        var depth = audio
        depth[34] = 32
        for response in [
            Data("not audio".utf8), Data(), Data(audio.dropLast()), stereo, depth,
            try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 0, count: 480), sampleRate: 16_000)),
            try wave(rate: 24_000), try wave(rate: 32_000)
        ] {
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), response) }
            do {
                _ = try await synthesize(source)
                XCTFail("Unsupported response was admitted")
            } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio) }
        }
        let other = try wave(rate: 24_000)
        StubURLProtocol.handler = { request in
            .respond(DeepgramSpeechFixture.response(request),
                try self.jsonBody(request)["text"] as? String == "x" ? other : audio)
        }
        let long = try VoiceOutputSourceSnapshot(source: .clipboard,
            text: String(repeating: "x", count: DeepgramSpeechRequest.maximumCharacters + 1))
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .clipboard, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(long) }
            XCTFail("A mixed-rate partial result was returned")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio) }
        XCTAssertEqual(capture.records.map(\.outcome), [.completed, .failed])
        XCTAssertNil(capture.records.last?.audioDuration)
    }

    func testBoundedTransportAndMissingKey_RefuseWithoutInventingCompletion() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic transport.")
        do {
            _ = try await synthesize(source, credential: { " " })
            XCTFail("Missing key admitted synthesis")
        } catch { XCTAssertEqual(error as? DesktopSpeechmaticsSpeechError, .missingCredential) }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        for code in [URLError.Code.cancelled, .timedOut] {
            StubURLProtocol.handler = { _ in .fail(URLError(code)) }
            do {
                _ = try await synthesize(source)
                XCTFail("Failed transport returned audio")
            } catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) } else {
                    XCTAssertEqual(error as? DesktopSpeechSynthesisError, .timedOut)
                }
            }
        }
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                httpVersion: nil, headerFields: [
                    "Content-Length": String(DeepgramSpeechSynthesizer.defaultResponseLimit + 1)
                ])), Data())
        }
        do {
            _ = try await synthesize(source)
            XCTFail("Oversized response was admitted")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .audioTooLarge) }
    }

    func testInFlightCancellation_StopsTheActualTransportAndAnyNextSegment() async throws {
        let started = expectation(description: "Speechmatics request started")
        let stopped = expectation(description: "Speechmatics request cancelled")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let source = try VoiceOutputSourceSnapshot(source: .typedText,
            text: String(repeating: "x", count: DeepgramSpeechRequest.maximumCharacters + 1))
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
        let task = Task {
            try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled request published audio")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(capture.records.map(\.outcome), [.cancelled])
    }

    private func wave(rate: Int = 16_000) throws -> Data {
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate))
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }

    private func synthesize(
        _ source: VoiceOutputSourceSnapshot,
        voice: DesktopSpeechVoice = .speechmatics(SpeechmaticsTTSCatalog.defaultVoice),
        options: VoiceSynthesisOptions? = nil,
        credential: @Sendable () async throws -> String = { "synthetic-key" }
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: voice, options: options ?? VoiceSynthesisOptions(), credential: credential)
    }
}
