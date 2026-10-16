import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopGeminiSpeechSynthesisTests: DeepgramSpeechStubTestCase {
    func testCanonicalVoices_ExecuteSharedRequestAndKeepReportedTokensDistinctFromUnknown() async throws {
        for (index, preset) in GeminiTTSCatalog.voices.enumerated() {
            let tokens: Int? = index.isMultiple(of: 3) ? nil : index.isMultiple(of: 2) ? 0 : 123
            let response = try audioResponse(tokens: tokens)
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), response) }
            let voice = DesktopSpeechVoice.gemini(preset)
            let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic cafe\u{301} input.")
            let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .clipboard, historyRecordID: UUID())
            let wav = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, voice: voice)
            }
            XCTAssertEqual(wav, DeepgramSpeechFixture.canonicalWAV(pcm: pcm))
            XCTAssertEqual(voice.apiKeyIdentifier, GeminiTTSCatalog.credentialIdentifier)
            XCTAssertEqual(voice.capabilities.nativeFlags, 0)
            XCTAssertNil(VoiceSynthesisPricing.estimate(for: voice, characterCount: 1_000))
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: voice.modelID, voiceID: voice.id), voice)
            let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
            XCTAssertEqual(request.url, GeminiTTSAPI.interactionsEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: GeminiTTSAPI.apiKeyHeader), "synthetic-key")
            let canonical = try GeminiTTSAPI.synthesisRequest(input: source.text, apiKey: "synthetic-key",
                request: GeminiTTSRequest(voiceID: voice.id))
            let submittedJSON = try JSONSerialization.data(withJSONObject: jsonBody(request), options: .sortedKeys)
            let canonicalJSON = try JSONSerialization.data(withJSONObject: jsonBody(canonical), options: .sortedKeys)
            XCTAssertEqual(submittedJSON, canonicalJSON)
            let record = try XCTUnwrap(capture.records.first)
            XCTAssertEqual(record.outcome, .completed)
            XCTAssertEqual(record.inputCharacters, source.text.unicodeScalars.count)
            XCTAssertNil(record.historyRecordID)
            XCTAssertEqual(record.reportedInputTokens, tokens)
            let duration = Double(pcm.count) / 48_000
            XCTAssertEqual(record.audioDuration, duration)
            XCTAssertEqual(record.estimatedAudioCostUSD, VoiceSynthesisPricing.geminiAudioEstimate(duration: duration))
            XCTAssertEqual(record.estimatedInputCostUSD,
                           VoiceSynthesisPricing.geminiInputEstimate(reportedTokens: tokens))
            if let tokens {
                XCTAssertEqual(record.estimatedCostUSD,
                    Decimal(duration) * GeminiTTSCatalog.defaultModel.costPerSecondOfSpeech
                    + Decimal(tokens) * GeminiTTSCatalog.defaultModel.costPerInputToken)
            } else { XCTAssertNil(record.estimatedCostUSD) }
        }
        XCTAssertEqual(GeminiTTSCatalog.voices.count, 30)
    }

    func testLongInput_UsesCanonicalChunksOneKeyAndTrueHistoryOwnership() async throws {
        let response = try audioResponse(tokens: 22)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), response) }
        let owner = UUID()
        let source = try VoiceOutputSourceSnapshot(source: .history,
            text: String(repeating: "Synthetic long input. ", count: 500), recordID: owner)
        let probe = CredentialProbe()
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .history, historyRecordID: owner)
        let wav = try await VoiceSynthesisUsage.$capture.withValue(capture) {
            try await self.synthesize(source, credential: { try await probe.supply() })
        }
        let segments = TTSTextChunker.chunks(source.text, maximumCharacters: GeminiTTSAPI.maxInputCharacters)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(try StubURLProtocol.recordedRequests.map { try jsonBody($0)["input"] as? String }, segments)
        XCTAssertEqual(wav, DeepgramSpeechFixture.canonicalWAV(pcm:
            Data((0..<segments.count).flatMap { _ in Array(pcm) })))
        XCTAssertEqual(capture.records.map(\.inputCharacters), segments.map { $0.unicodeScalars.count })
        XCTAssertTrue(capture.records.allSatisfy { $0.historyRecordID == owner && $0.reportedInputTokens == 22 })
    }

    func testUnsupportedControlsAndForeignSelections_RefuseBeforeKeyWithoutFallback() async throws {
        let voice = DesktopSpeechVoice.gemini(GeminiTTSCatalog.defaultVoice)
        for model in [nil, voice.modelID, GeminiTTSCatalog.providerIdentifier, GeminiTTSCatalog.defaultModel.rawValue] {
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: model, voiceID: voice.id), voice)
        }
        for (model, identifier) in [
            (voice.modelID, "google/unknown"), ("google/gemini-3.5-transcribe", voice.id),
            ("gemini-2.5-flash-preview-tts", voice.id), ("azure/neural", voice.id), (voice.modelID, "xai/eve")
        ] {
            XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: model, voiceID: identifier))
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic refusal.")
        let probe = CredentialProbe()
        for options in [
            try VoiceSynthesisOptions(speed: 1.25), try VoiceSynthesisOptions(pitch: -2),
            try VoiceSynthesisOptions(useSSML: true)
        ] {
            do {
                _ = try await synthesize(source, options: options, credential: { try await probe.supply() })
                XCTFail("Unsupported Gemini controls were ignored")
            } catch { XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedControls) }
        }
        do {
            _ = try await synthesize(source, voice: .gemini(.init(id: "Unknown", character: "Unavailable")),
                                     credential: { try await probe.supply() })
            XCTFail("Unknown Gemini voice fell back")
        } catch { XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedVoice) }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testCanonicalRetry_RecordsEveryAttemptWithoutFalseDurationOrDuplicateTokens() async throws {
        let response = try audioResponse(tokens: 17)
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic retry.")
        let noAudio = try JSONSerialization.data(withJSONObject: [
            "steps": [["content": [["type": "text", "data": "private provider text"]]]],
            "usage": ["input_tokens": 7]
        ])
        for (status, first, inputTokens) in [
            (200, noAudio, Optional(7)),
            (500, Data(#"{"error":{"message":"private provider fault"}}"#.utf8), nil)
        ] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                StubURLProtocol.recordedRequests.count == 1
                    ? .respond(DeepgramSpeechFixture.response(request, status: status), first)
                    : .respond(DeepgramSpeechFixture.response(request), response)
            }
            let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
            XCTAssertEqual(capture.records.map(\.outcome), [.failed, .completed])
            XCTAssertNil(capture.records.first?.audioDuration)
            XCTAssertEqual(capture.records.first?.reportedInputTokens, inputTokens)
            XCTAssertEqual(capture.records.last?.reportedInputTokens, 17)
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, GeminiTTSAPI.serverFaultRetries + 1)
        }
    }

    func testMissingCredentialAndPrecancelledWork_DoNotAdmitRequestsOrUsage() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic preflight.")
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .typedText, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, credential: { "" })
            }
            XCTFail("Missing credential admitted synthesis")
        } catch { XCTAssertEqual(error as? DesktopGeminiSpeechError, .missingCredential) }
        let probe = CredentialProbe()
        let task = Task {
            try await VoiceSynthesisUsage.$capture.withValue(capture) {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await self.synthesize(source, credential: { try await probe.supply() })
            }
        }
        do {
            _ = try await task.value
            XCTFail("Precancelled work admitted synthesis")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(capture.records.isEmpty)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testServiceFailures_UseCanonicalDecisionsWithoutEchoingBodiesOrUnboundedRetry() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .textFile, text: "Synthetic failures.")
        for (status, code, expected, attempts) in [
            (401, "authentication", DesktopGeminiSpeechError.unauthorized, 1),
            (403, "permission_denied", .permissionDenied, 1), (429, "quota_exceeded", .rateLimited, 1),
            (400, "safety", .contentBlocked, 1), (503, "unknown", .service(503), 2)
        ] {
            StubURLProtocol.reset()
            let body = try JSONSerialization.data(withJSONObject:
                ["error": ["code": code, "message": "private provider body"]])
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0, status: status), body) }
            do {
                _ = try await synthesize(source)
                XCTFail("Failed Gemini response returned audio")
            } catch {
                XCTAssertEqual(error as? DesktopGeminiSpeechError, expected)
                XCTAssertFalse(error.localizedDescription.contains("private provider body"))
            }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, attempts)
        }
    }

    func testInvalidAudioAndUsage_RefuseUnsupportedResultsWithoutInventingTokens() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic invalid results.")
        for response in [
            try audioResponse(bytes: Data(repeating: 0, count: 480)), try audioResponse(bytes: Data([1])),
            try audioResponse(rate: 16_000), try audioResponse(channels: 2), try audioResponse(tokens: -1),
            try audioResponse(bytes: Data("invalid container".utf8), mime: "audio/wav"),
            Data(#"{"steps":[]}"#.utf8), Data("invalid JSON".utf8)
        ] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), response) }
            let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .clipboard, historyRecordID: nil)
            do {
                _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
                XCTFail("Invalid Gemini result returned audio")
            } catch {
                XCTAssertTrue(error is DesktopSpeechSynthesisError || error is DesktopGeminiSpeechError)
            }
            XCTAssertTrue(capture.records.allSatisfy { $0.outcome == .failed && $0.audioDuration == nil })
            XCTAssertLessThanOrEqual(capture.records.count, 2)
        }
    }

    func testTransportBoundsCancellationAndLaterChunkFailure_NeverReturnPartialAudio() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic bounded transport.")
        let response = try audioResponse(tokens: 5)
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                httpVersion: nil, headerFields: [
                    "Content-Length": String(DeepgramSpeechSynthesizer.defaultResponseLimit + 1)
                ])), response)
        }
        do {
            _ = try await synthesize(source)
            XCTFail("Oversized response was admitted")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .audioTooLarge) }
        for (code, cancelled) in [(URLError.cancelled, true), (.timedOut, false)] {
            StubURLProtocol.handler = { _ in .fail(URLError(code)) }
            let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .typedText, historyRecordID: nil)
            do {
                _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
                XCTFail("Failed transport returned audio")
            } catch {
                if cancelled { XCTAssertTrue(error is CancellationError) } else {
                    XCTAssertEqual(error as? DesktopSpeechSynthesisError, .timedOut)
                }
            }
            XCTAssertEqual(capture.records.map(\.outcome), [cancelled ? .cancelled : .failed])
            XCTAssertNil(capture.records.first?.reportedInputTokens)
        }
        StubURLProtocol.reset()
        let long = try VoiceOutputSourceSnapshot(source: .typedText,
            text: String(repeating: "Synthetic long input. ", count: 500))
        let first = try XCTUnwrap(TTSTextChunker.chunks(long.text,
            maximumCharacters: GeminiTTSAPI.maxInputCharacters).first)
        StubURLProtocol.handler = { request in
            try self.jsonBody(request)["input"] as? String == first
                ? .respond(DeepgramSpeechFixture.response(request), response)
                : .respond(DeepgramSpeechFixture.response(request, status: 401), Data("private failure".utf8))
        }
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .typedText, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(long) }
            XCTFail("Later failure published partial audio")
        } catch { XCTAssertEqual(error as? DesktopGeminiSpeechError, .unauthorized) }
        XCTAssertEqual(capture.records.map(\.outcome), [.completed, .failed])
        XCTAssertEqual(capture.records.first?.reportedInputTokens, 5)
        XCTAssertNil(capture.records.last?.reportedInputTokens)
    }

}

private extension DesktopGeminiSpeechSynthesisTests {
    func audioResponse(
        bytes: Data? = nil, tokens: Int? = nil, rate: Int = 24_000, channels: Int = 1, mime: String = "audio/l16"
    ) throws -> Data {
        var body: [String: Any] = ["steps": [["content": [[
            "type": "audio", "data": (bytes ?? pcm).base64EncodedString(),
            "mime_type": mime, "sample_rate": rate, "channels": channels
        ]]]]]
        if let tokens { body["usage"] = ["input_tokens": tokens] }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }

    func synthesize(
        _ source: VoiceOutputSourceSnapshot,
        voice: DesktopSpeechVoice = .gemini(GeminiTTSCatalog.defaultVoice),
        options: VoiceSynthesisOptions? = nil,
        credential: @Sendable () async throws -> String = { "synthetic-key" }
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: voice, options: options ?? VoiceSynthesisOptions(), credential: credential)
    }
}
