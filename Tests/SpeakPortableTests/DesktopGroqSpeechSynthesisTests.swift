import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopGroqSpeechSynthesisTests: DeepgramSpeechStubTestCase {
    func testCanonicalPersonas_UseSharedRequestsWAVAndMeasuredUsageWithoutTokens() async throws {
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        for preset in GroqTTSCatalog.voices {
            let voice = DesktopSpeechVoice.groq(preset)
            let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic cafe\u{301} input.")
            let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .clipboard, historyRecordID: UUID())
            let result = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, voice: voice)
            }
            XCTAssertEqual(result, audio)
            XCTAssertEqual(voice.apiKeyIdentifier, GroqTTSCatalog.credentialIdentifier)
            XCTAssertEqual(voice.capabilities.nativeFlags, 0)
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: voice.modelID, voiceID: voice.id), voice)
            let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
            XCTAssertEqual(request.url, GroqTTSAPI.speechEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                           ["Bearer", "synthetic-key"].joined(separator: " "))
            let body = try jsonBody(request)
            XCTAssertEqual(body["model"] as? String, preset.model.rawValue)
            XCTAssertEqual(body["voice"] as? String, preset.apiVoiceID)
            XCTAssertEqual(body["input"] as? String, source.text)
            XCTAssertEqual(body["response_format"] as? String, "wav")
            XCTAssertEqual(Set(body.keys), ["model", "voice", "input", "response_format"])
            let record = try XCTUnwrap(capture.records.first)
            XCTAssertEqual(record.outcome, .completed)
            XCTAssertEqual(record.inputCharacters, source.text.unicodeScalars.count)
            XCTAssertEqual(record.audioDuration, Double(pcm.count) / 48_000)
            XCTAssertNil(record.historyRecordID)
            XCTAssertNil(record.reportedInputTokens)
            XCTAssertNil(record.estimatedInputCostUSD)
            XCTAssertNil(record.estimatedAudioCostUSD)
            XCTAssertEqual(record.estimatedCostUSD,
                Decimal(source.text.count) * preset.model.costPerThousandCharacters / 1_000)
        }
        XCTAssertEqual(GroqTTSCatalog.voices.filter { $0.model.languageCode == "en" }.count, 6)
        XCTAssertEqual(GroqTTSCatalog.voices.filter { $0.model.languageCode == "ar" }.count, 6)
    }

    func testCharacterBoundaries_AllowExactlySixtySequentialRequestsWithOneKeyAndRealOwner() async throws {
        for (count, lengths) in [(199, [199]), (200, [200]), (201, [200, 1])] {
            XCTAssertEqual(try GroqTTSAPI.synthesisSegments(String(repeating: "x", count: count)).map(\.count), lengths)
        }
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let owner = UUID()
        let source = try VoiceOutputSourceSnapshot(source: .history,
            text: String(repeating: "x", count: 12_000), recordID: owner)
        let probe = CredentialProbe()
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .history, historyRecordID: owner)
        let result = try await VoiceSynthesisUsage.$capture.withValue(capture) {
            try await self.synthesize(source, credential: { try await probe.supply() })
        }
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 60)
        XCTAssertEqual(capture.records.count, 60)
        XCTAssertEqual(Set(capture.records.map(\.id)).count, 60)
        XCTAssertTrue(capture.records.allSatisfy { $0.historyRecordID == owner && $0.inputCharacters == 200 })
        XCTAssertEqual(result, DeepgramSpeechFixture.canonicalWAV(pcm:
            Data((0..<60).flatMap { _ in Array(pcm) })))
        let submitted = try StubURLProtocol.recordedRequests.map { try XCTUnwrap(jsonBody($0)["input"] as? String) }
        XCTAssertEqual(submitted, try GroqTTSAPI.synthesisSegments(source.text))
    }

    func testFanOutAndUnsupportedControls_RefuseBeforeCredentialsOrUsage() async throws {
        let probe = CredentialProbe()
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
        let long = try VoiceOutputSourceSnapshot(source: .typedText, text: String(repeating: "x", count: 12_001))
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(long, credential: { try await probe.supply() })
            }
            XCTFail("61 requests were admitted")
        } catch { XCTAssertEqual(error as? DesktopGroqSpeechError, .excessiveFanOut(61)) }
        XCTAssertThrowsError(try VoiceSynthesisPricing.estimate(
            for: .groq(GroqTTSCatalog.defaultVoice), text: long.text)) { error in
            XCTAssertEqual(error as? DesktopGroqSpeechError, .excessiveFanOut(61))
            XCTAssertTrue(error.localizedDescription.contains("61 separate requests"))
        }
        XCTAssertThrowsError(try VoiceSynthesisPricing.estimate(
            for: .groq(GroqTTSCatalog.defaultVoice), text: " \n ")) { error in
            XCTAssertEqual(error as? DesktopGroqSpeechError, .emptyText)
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic refusal.")
        for options in [
            try VoiceSynthesisOptions(speed: 1.25), try VoiceSynthesisOptions(pitch: 1),
            try VoiceSynthesisOptions(useSSML: true)
        ] {
            do {
                _ = try await synthesize(source, options: options, credential: { try await probe.supply() })
                XCTFail("Unsupported controls were ignored")
            } catch { XCTAssertTrue(error is VoiceSynthesisConfigurationError) }
        }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(capture.records.isEmpty)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testStrictResolution_RefusesWrongModelForeignUnknownAndRetiredVoicesWithoutFallback() throws {
        let voice = DesktopSpeechVoice.groq(GroqTTSCatalog.defaultVoice)
        let models = [nil, GroqTTSCatalog.providerIdentifier, voice.modelID, GroqTTSCatalog.defaultVoice.model.rawValue]
        for model in models {
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: model, voiceID: voice.id), voice)
        }
        for (model, identifier) in [
            (voice.modelID, "groq/orpheus-v1-english/tara"),
            ("groq/unknown/autumn", voice.id), ("playai-tts", voice.id),
            ("groq/canopylabs/orpheus-arabic-saudi", voice.id),
            ("canopylabs/orpheus-arabic-saudi", "autumn"),
            ("azure/neural", voice.id), (voice.modelID, "xai/eve"),
            (voice.modelID, "groq/orpheus-arabic-saudi/autumn")
        ] {
            XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: model, voiceID: identifier))
        }
    }

    func testUnicodePricing_UsesSubmittedGraphemesNotScalarsOrDiscardedWhitespace() throws {
        let voice = DesktopSpeechVoice.groq(try XCTUnwrap(
            GroqTTSCatalog.voices.first { $0.model == .orpheusArabicSaudi }))
        let text = "  " + String(repeating: "cafe\u{301}", count: 51) + " \n "
        let segments = try GroqTTSAPI.synthesisSegments(text)
        XCTAssertEqual(segments.map(\.count), [200, 4])
        XCTAssertEqual(segments.reduce(0) { $0 + $1.unicodeScalars.count }, 255)
        XCTAssertEqual(try VoiceSynthesisPricing.estimate(for: voice, text: text),
                       Decimal(204) * GroqTTSModel.orpheusArabicSaudi.costPerThousandCharacters / 1_000)
        XCTAssertEqual(VoiceSynthesisPricing.ratePerThousandCharacters(for: voice), Decimal(string: "0.040"))
        XCTAssertEqual(VoiceSynthesisPricing.ratePerThousandCharacters(
            for: .groq(GroqTTSCatalog.defaultVoice)), Decimal(string: "0.022"))
    }

    func testServiceFailures_DistinguishTermsAccessQuotaAndKeyWithoutEchoingBody() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic failure.")
        for (status, code, expected) in [
            (400, "model_terms_required", DesktopGroqSpeechError.modelTermsRequired),
            (400, "blocked_api_access", .accessBlocked), (400, "model_permission_blocked_org", .accessBlocked),
            (400, "model_permission_blocked_project", .accessBlocked), (403, "", .accessBlocked),
            (401, "", .unauthorized), (429, "", .rateLimited), (503, "", .service(503))
        ] {
            let body = try JSONSerialization.data(withJSONObject: [
                "error": ["code": code, "message": "private provider body"]
            ])
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0, status: status), body) }
            let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .typedText, historyRecordID: nil)
            do {
                _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
                XCTFail("Failed request returned audio")
            } catch {
                XCTAssertEqual(error as? DesktopGroqSpeechError, expected)
                XCTAssertFalse(error.localizedDescription.contains("private provider body"))
            }
            XCTAssertEqual(capture.records.first?.outcome, .failed)
            XCTAssertNil(capture.records.first?.audioDuration)
            XCTAssertNil(capture.records.first?.reportedInputTokens)
        }
    }

    func testInvalidAudioAndOversizedResponse_NeverPublishResults() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .textFile, text: "Synthetic audio validation.")
        var stereo = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        stereo[22] = 2
        var wrongDepth = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        wrongDepth[34] = 32
        for audio in [
            Data("invalid".utf8), DeepgramSpeechFixture.canonicalWAV(pcm: Data()),
            DeepgramSpeechFixture.canonicalWAV(pcm: Data(repeating: 0, count: 480)),
            try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000)),
            Data(DeepgramSpeechFixture.canonicalWAV(pcm: pcm).dropLast()), stereo, wrongDepth
        ] {
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
            do {
                _ = try await synthesize(source)
                XCTFail("Invalid WAV was admitted")
            } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio) }
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

    func testCancellationTimeoutMissingKeyAndLaterFailure_DoNotReturnPartialOrFalseMeasuredAudio() async throws {
        let short = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic cancellation.")
        do {
            _ = try await synthesize(short, credential: { " " })
            XCTFail("Missing key admitted synthesis")
        } catch { XCTAssertEqual(error as? DesktopGroqSpeechError, .missingCredential) }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        let failures = [(URLError.Code.cancelled, VoiceSynthesisUsage.Outcome.cancelled), (.timedOut, .failed)]
        for (code, outcome) in failures {
            StubURLProtocol.handler = { _ in .fail(URLError(code)) }
            let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .typedText, historyRecordID: nil)
            do {
                _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(short) }
                XCTFail("Failed transport returned audio")
            } catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) } else {
                    XCTAssertEqual(error as? DesktopSpeechSynthesisError, .timedOut)
                }
            }
            XCTAssertEqual(capture.records.first?.outcome, outcome)
            XCTAssertNil(capture.records.first?.audioDuration)
        }
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: String(repeating: "x", count: 201))
        StubURLProtocol.handler = { request in
            try self.jsonBody(request)["input"] as? String == "x"
                ? .respond(DeepgramSpeechFixture.response(request, status: 503), Data())
                : .respond(DeepgramSpeechFixture.response(request), DeepgramSpeechFixture.canonicalWAV(pcm: self.pcm))
        }
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .clipboard, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
            XCTFail("Later failure returned partial audio")
        } catch { XCTAssertEqual(error as? DesktopGroqSpeechError, .service(503)) }
        XCTAssertEqual(capture.records.map(\.outcome), [.completed, .failed])
        XCTAssertNil(capture.records.last?.audioDuration)
    }

    func testInFlightCancellation_ClosesTransportBeforeAnyLaterSegment() async throws {
        let started = expectation(description: "First Groq request started")
        let stopped = expectation(description: "First Groq request cancelled")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: String(repeating: "x", count: 201))
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
        let task = Task {
            try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled in-flight request published audio")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(capture.records.map(\.outcome), [.cancelled])
        XCTAssertNil(capture.records.first?.audioDuration)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }

    private func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice = .groq(GroqTTSCatalog.defaultVoice),
        options: VoiceSynthesisOptions? = nil,
        credential: @Sendable () async throws -> String = { "synthetic-key" }
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: voice, options: options ?? VoiceSynthesisOptions(), credential: credential)
    }
}
