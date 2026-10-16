import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopOpenAISpeechSynthesisTests: DeepgramSpeechStubTestCase {
    func testCanonicalCompatibility_PreservesMacIdentifiersDefaultsAndEveryExecutableTuple() async throws {
        XCTAssertEqual(OpenAITTSCatalog.voices.map(\.id),
            ["alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer", "verse"])
        XCTAssertEqual(OpenAITTSCatalog.defaultModel, .standard)
        XCTAssertEqual(try OpenAITTSCatalog.model(forQualityIdentifier: "standard"), .mini)
        XCTAssertEqual(try OpenAITTSCatalog.model(forQualityIdentifier: "high"), .standard)
        XCTAssertEqual(try OpenAITTSCatalog.model(forQualityIdentifier: "highest"), .highDefinition)
        XCTAssertThrowsError(try OpenAITTSCatalog.model(forQualityIdentifier: "unknown"))
        let audio = try wave()
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic cafe\u{301}.")
        for model in OpenAITTSCatalog.models {
            let voices = OpenAITTSCatalog.voices(for: model)
            XCTAssertEqual(voices.count, model == .mini ? 11 : 9)
            for preset in voices {
                let voice = DesktopSpeechVoice.openai(model, preset)
                XCTAssertEqual(voice.apiKeyIdentifier, "openai.tts.apiKey")
                XCTAssertEqual(voice.sampleRate, 24_000)
                XCTAssertEqual(voice.capabilities.nativeFlags, 1)
                XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: voice.modelID, voiceID: voice.id), voice)
                XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: model.rawValue, voiceID: voice.id), voice)
                let capture = VoiceSynthesisUsage.Capture(
                    operation: .generate, source: .clipboard, historyRecordID: UUID())
                let result = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                    try await self.synthesize(source, voice: voice, options: VoiceSynthesisOptions(speed: 1.5))
                }
                XCTAssertEqual(result, audio)
                let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
                XCTAssertEqual(request.url, OpenAITTSAPI.endpoint)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                               ["Bearer", "synthetic-key"].joined(separator: " "))
                XCTAssertEqual(try jsonBody(request) as NSDictionary, [
                    "model": model.rawValue, "voice": preset.id, "input": source.text,
                    "speed": 1.5, "response_format": "wav"
                ] as NSDictionary)
                let record = try XCTUnwrap(capture.records.first)
                XCTAssertEqual(record.outcome, .completed)
                XCTAssertEqual(record.inputCharacters, source.text.unicodeScalars.count)
                XCTAssertEqual(record.audioDuration, Double(pcm.count) / 48_000)
                XCTAssertNil(record.historyRecordID)
                XCTAssertNil(record.reportedInputTokens)
                XCTAssertNil(record.estimatedInputCostUSD)
                XCTAssertNil(record.estimatedAudioCostUSD)
                XCTAssertEqual(record.estimatedCostUSD,
                    model.costPerThousandCharacters.map { Decimal(source.text.count) * $0 / 1_000 })
            }
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 29)
    }

    func testSharedMacRequestShapes_PreserveFormatsAndSupportedSpeedWithoutInstructions() throws {
        for format in [OpenAITTSOutputFormat.mp3, .aac, .wav] {
            for speed in [0.25, 1, 4] {
                let request = try OpenAITTSAPI.synthesisRequest(text: "Synthetic Mac.", apiKey: "synthetic-key",
                    request: .init(model: .mini, voiceID: "openai/verse", speed: speed, format: format))
                let body = try jsonBody(request)
                XCTAssertEqual(body["response_format"] as? String, format.rawValue)
                XCTAssertEqual(body["speed"] as? Double, speed)
                XCTAssertEqual(body.count, 5)
            }
        }
        for speed in [Double.nan, .infinity, 0.24, 4.01] {
            XCTAssertThrowsError(try OpenAITTSAPI.synthesisRequest(text: "Synthetic refusal.", apiKey: "key",
                request: .init(model: .standard, voiceID: "alloy", speed: speed)))
        }
    }

    func testStrictTupleAndControls_RefuseBeforeKeysAndNeverSubstituteModelOrVoice() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic refusal.")
        for (model, identifier) in [
            ("tts-1", "openai/ballad"), ("openai/tts-1-hd", "openai/verse"),
            ("openai/unknown", "openai/alloy"), ("azure/neural", "openai/alloy"),
            ("openai/tts-1", "azure/alloy"), ("openai", "openai/unknown"),
            ("gpt-4o-mini-tts", "openai/alloy/other")
        ] {
            XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: model, voiceID: identifier))
        }
        let probe = CredentialProbe()
        let preset = try XCTUnwrap(OpenAITTSCatalog.voice(forID: "alloy"))
        let forged = OpenAITTSVoice(id: "alloy", name: "Foreign", traits: [], supportsLegacyModels: true)
        for voice in [DesktopSpeechVoice.openai(.standard, forged),
                      .openai(.standard, try XCTUnwrap(OpenAITTSCatalog.voice(forID: "verse")))] {
            do {
                _ = try await synthesize(source, voice: voice, credential: { try await probe.supply() })
                XCTFail("A noncanonical tuple was admitted")
            } catch { XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedVoice) }
        }
        for options in [try VoiceSynthesisOptions(pitch: 1), try VoiceSynthesisOptions(useSSML: true)] {
            do {
                _ = try await synthesize(source, options: options, credential: { try await probe.supply() })
                XCTFail("Unsupported controls were ignored")
            } catch { XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedControls) }
        }
        XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: nil, voiceID: preset.providerVoiceID),
                       .openai(.standard, preset))
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testSegmentation_UsesOneKeyBoundedRequestsRealHistoryOwnerAndExactJoinedPCM() async throws {
        let audio = try wave()
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let source = try VoiceOutputSourceSnapshot(source: .history,
            text: String(repeating: "x", count: OpenAITTSAPI.maximumInputScalars + 1), recordID: UUID())
        let probe = CredentialProbe()
        let capture = VoiceSynthesisUsage.Capture(
            operation: .export, source: .history, historyRecordID: source.recordID)
        let result = try await VoiceSynthesisUsage.$capture.withValue(capture) {
            try await self.synthesize(source, credential: { try await probe.supply() })
        }
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(result, try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm + pcm, sampleRate: 24_000)))
        XCTAssertEqual(capture.records.map(\.inputCharacters), [4_096, 1])
        XCTAssertTrue(capture.records.allSatisfy { $0.historyRecordID == source.recordID })
        let inputs = try StubURLProtocol.recordedRequests.map { try XCTUnwrap(jsonBody($0)["input"] as? String) }
        XCTAssertEqual(inputs.joined(), source.text)
        let hugeGrapheme = "a" + String(repeating: "\u{301}", count: OpenAITTSAPI.maximumInputScalars)
        let impossible = try VoiceOutputSourceSnapshot(source: .typedText, text: hugeGrapheme)
        do {
            _ = try await synthesize(impossible, credential: { try await probe.supply() })
            XCTFail("An indivisible oversized grapheme admitted a request")
        } catch { XCTAssertEqual(error as? OpenAITTSAPIError, .inputTooLarge) }
        XCTAssertEqual(probe.count, 1)
        XCTAssertThrowsError(try OpenAITTSAPI.synthesisSegments(" \n "))
    }

    func testPricing_MiniKeepsChargesUnestimatedAndClassicCountsSubmittedGraphemesOnly() throws {
        let preset = try XCTUnwrap(OpenAITTSCatalog.voice(forID: "alloy"))
        let text = "  cafe\u{301}  \n "
        for model in OpenAITTSCatalog.models {
            let voice = DesktopSpeechVoice.openai(model, preset)
            XCTAssertEqual(try VoiceSynthesisPricing.estimate(for: voice, text: text),
                           model.costPerThousandCharacters.map { Decimal(4) * $0 / 1_000 })
        }
        XCTAssertNil(VoiceSynthesisPricing.estimate(for: .openai(.mini, preset), characterCount: 100))
        XCTAssertTrue(VoiceSynthesisPricing.estimateBasis(for: .openai(.mini, preset))?.contains("unestimated") == true)
    }

    func testWrongRateMalformedSilenceAndLateFailure_NeverPublishPartialAudio() async throws {
        let audio = try wave()
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic invalid audio.")
        var stereo = audio
        stereo[22] = 2
        var depth = audio
        depth[34] = 32
        for data in [Data(), Data("not audio".utf8), Data(audio.dropLast()), stereo, depth,
                     try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000)),
                     try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 0, count: 480), sampleRate: 24_000))] {
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), data) }
            do {
                _ = try await synthesize(source)
                XCTFail("Invalid audio was accepted")
            } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio) }
        }
        let long = try VoiceOutputSourceSnapshot(source: .typedText,
            text: String(repeating: "x", count: OpenAITTSAPI.maximumInputScalars + 1))
        StubURLProtocol.handler = { request in
            .respond(DeepgramSpeechFixture.response(request),
                try self.jsonBody(request)["input"] as? String == "x" ? Data("bad".utf8) : audio)
        }
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(long) }
            XCTFail("A partial result was published")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio) }
        XCTAssertEqual(capture.records.map(\.outcome), [.completed, .failed])
        XCTAssertNil(capture.records.last?.audioDuration)
    }

    func testServiceMissingKeyAndBoundedTransport_KeepSanitizedErrorsAndNoFalseUsage() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .textFile, text: "Synthetic service failure.")
        for status in [401, 403, 429, 503] {
            StubURLProtocol.handler = {
                .respond(DeepgramSpeechFixture.response($0, status: status), Data("private body".utf8))
            }
            do {
                _ = try await synthesize(source)
                XCTFail("HTTP failure returned audio")
            } catch {
                XCTAssertEqual(error as? OpenAITTSAPIError, .service(status))
                XCTAssertFalse(error.localizedDescription.contains("private body"))
            }
        }
        do {
            _ = try await synthesize(source, credential: { " " })
            XCTFail("Missing key was admitted")
        } catch { XCTAssertEqual(error as? OpenAITTSAPIError, .missingCredential) }
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

    func testCancellation_StopsActualTransportBeforeAnyNextRequestOrPublication() async throws {
        let started = expectation(description: "OpenAI admitted")
        let stopped = expectation(description: "OpenAI cancelled")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let source = try VoiceOutputSourceSnapshot(source: .typedText,
            text: String(repeating: "x", count: OpenAITTSAPI.maximumInputScalars + 1))
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .typedText, historyRecordID: nil)
        let task = Task {
            try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled audio was published")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(capture.records.map(\.outcome), [.cancelled])
    }

    private func wave() throws -> Data {
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000))
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }

    private func synthesize(
        _ source: VoiceOutputSourceSnapshot,
        voice: DesktopSpeechVoice = .openai(.standard, OpenAITTSCatalog.voices[0]),
        options: VoiceSynthesisOptions? = nil,
        credential: @Sendable () async throws -> String = { "synthetic-key" }
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: voice, options: options ?? VoiceSynthesisOptions(), credential: credential)
    }
}
