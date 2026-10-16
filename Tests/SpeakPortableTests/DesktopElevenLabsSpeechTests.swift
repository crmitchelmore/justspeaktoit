import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopElevenLabsSpeechTests: DeepgramSpeechStubTestCase {
    func testEveryCanonicalTuple_UsesCaseSensitiveVoiceRealWAVAndCanonicalKey() async throws {
        let audio = try wave()
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic cafe\u{301}.")
        for model in ElevenLabsTTSModels.all {
            for preset in ElevenLabsTTSCatalog.voices {
                let voice = DesktopSpeechVoice.elevenlabs(model, preset)
                XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: voice.modelID, voiceID: voice.id), voice)
                XCTAssertEqual(voice.apiKeyIdentifier, "elevenlabs.apiKey")
                XCTAssertEqual(try VoiceOutputCredentialSlot(voice: voice).identifier, "elevenlabs.apiKey")
                XCTAssertEqual(voice.capabilities.nativeFlags, 0)
                XCTAssertEqual(voice.sampleRate, 24_000)
                let output = try await synthesize(source, voice: voice)
                XCTAssertEqual(output, audio)
                let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
                let dialogue = ElevenLabsTTSModels.dialogueOnlyModelIDs.contains(model.id)
                XCTAssertEqual(request.url?.path, dialogue ? "/v1/text-to-dialogue"
                    : "/v1/text-to-speech/" + preset.id)
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.query,
                               "output_format=wav_24000")
                XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "synthetic-key")
                XCTAssertEqual(request.httpMethod, "POST")
                let json = try body(request)
                XCTAssertEqual(json["model_id"] as? String, model.id)
                if dialogue {
                    XCTAssertEqual(json["inputs"] as? [[String: String]],
                                   [["text": source.text, "voice_id": preset.id]])
                    XCTAssertNil(json["voice_settings"])
                    XCTAssertNil(json["text"])
                } else {
                    XCTAssertEqual(json["text"] as? String, source.text)
                    let settings = try XCTUnwrap(json["voice_settings"] as? [String: Any])
                    XCTAssertEqual(settings["stability"] as? Double, 0.5)
                    XCTAssertEqual(settings["similarity_boost"] as? Double, 0.75)
                    XCTAssertEqual(settings["style"] as? Double, 0)
                    XCTAssertEqual(settings["use_speaker_boost"] as? Bool, true)
                    XCTAssertNil(settings["speed"])
                }
            }
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 32)
    }

    func testDialogueRejections_OnlyCanonicalStatusesFallbackWithSameVoiceKeyAndActualUsageModel() async throws {
        let audio = try wave()
        let source = try VoiceOutputSourceSnapshot(source: .history, text: "Synthetic dialogue.", recordID: UUID())
        for status in [400, 403, 404, 422] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                .respond(DeepgramSpeechFixture.response(request,
                    status: request.url?.path == "/v1/text-to-dialogue" ? status : 200), audio)
            }
            let keys = CredentialProbe()
            let capture = VoiceSynthesisUsage.Capture(
                operation: .read, source: .history, historyRecordID: source.recordID)
            let result = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, voice: self.voice(ElevenLabsTTSModels.elevenV4),
                                          credential: { try await keys.supply() })
            }
            XCTAssertEqual(result, audio)
            XCTAssertEqual(keys.count, 1)
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
            XCTAssertEqual(Set(StubURLProtocol.recordedRequests.compactMap {
                $0.value(forHTTPHeaderField: "xi-api-key")
            }), Set(["fixture-key"]))
            XCTAssertEqual(StubURLProtocol.recordedRequests.last?.url?.path,
                           "/v1/text-to-speech/" + ElevenLabsTTSCatalog.voices[0].id)
            XCTAssertEqual(capture.records.map(\.modelID),
                [ElevenLabsTTSModels.elevenV4.desktopModelIdentifier,
                 ElevenLabsTTSModels.elevenV3.desktopModelIdentifier])
            XCTAssertEqual(capture.records.map(\.outcome), [.failed, .completed])
            XCTAssertTrue(capture.records.allSatisfy { $0.voiceID == ElevenLabsTTSCatalog.voices[0].providerVoiceID })
            XCTAssertTrue(capture.records.allSatisfy { $0.historyRecordID == source.recordID })
            XCTAssertNil(capture.records.first?.audioDuration)
            XCTAssertEqual(try body(try XCTUnwrap(StubURLProtocol.recordedRequests.last))["text"] as? String,
                           source.text)
        }
    }

    func testDialogueBoundary_DecidesFallbackBeforeSegmentationAndNeverFlattensV4IntoSpeech() async throws {
        let audio = try wave()
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        for count in [2_000, 2_001, 5_001] {
            let previous = StubURLProtocol.recordedRequests.count
            let source = try VoiceOutputSourceSnapshot(source: .textFile, text: String(repeating: "x", count: count))
            _ = try await synthesize(source, voice: voice(ElevenLabsTTSModels.elevenV4))
            let requests = Array(StubURLProtocol.recordedRequests.dropFirst(previous))
            XCTAssertEqual(requests.count, count > 5_000 ? 2 : 1)
            if count == 2_000 {
                XCTAssertEqual(requests.first?.url?.path, "/v1/text-to-dialogue")
            } else {
                XCTAssertTrue(requests.allSatisfy { $0.url?.path.contains("text-to-speech/") == true })
                XCTAssertEqual(try requests.map { try body($0)["model_id"] as? String },
                               Array(repeating: "eleven_v3", count: requests.count))
                XCTAssertEqual(try requests.compactMap { try body($0)["text"] as? String }.joined(), source.text)
            }
        }
        XCTAssertThrowsError(try ElevenLabsTTSAPI.speechRequest(
            text: "Synthetic", voiceID: ElevenLabsTTSCatalog.voices[0].id, modelID: "eleven_v4", apiKey: "key"))
    }

    func testNonFallbackErrorsAndInvalidSuccessfulAudio_NeverSwitchModelsOrExposeResponseBodies() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic refusal.")
        for status in [401, 429, 500, 503] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = {
                .respond(DeepgramSpeechFixture.response($0, status: status), Data("private body".utf8))
            }
            do {
                _ = try await synthesize(source, voice: voice(ElevenLabsTTSModels.elevenV4))
                XCTFail("A service failure was hidden")
            } catch {
                XCTAssertEqual(error as? ElevenLabsTTSAPIError, .service(status))
                XCTAssertFalse(error.localizedDescription.contains("private body"))
            }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        }
        let audio = try wave()
        var stereo = audio
        stereo[22] = 2
        let invalid = [Data(), pcm, Data("mp3".utf8), Data(audio.dropLast()), stereo,
                       try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000)),
                       try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 0, count: 480), sampleRate: 24_000))]
        for data in invalid {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), data) }
            do {
                _ = try await synthesize(source, voice: voice(ElevenLabsTTSModels.elevenV4))
                XCTFail("Invalid or raw audio was accepted")
            } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio) }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        }
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await synthesize(source, voice: voice(ElevenLabsTTSModels.elevenV4))
            XCTFail("Transport failure was hidden")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .transportFailure) }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                httpVersion: nil, headerFields: [
                    "Content-Length": String(DeepgramSpeechSynthesizer.defaultResponseLimit + 1)
                ])), Data())
        }
        do {
            _ = try await synthesize(source, voice: voice(ElevenLabsTTSModels.elevenV4))
            XCTFail("Response bound was ignored")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .audioTooLarge) }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testControlsUnknownTuplesAndOversizedBodies_RefuseBeforeCredentialAccess() async throws {
        let keys = CredentialProbe()
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic refusal.")
        for options in [try VoiceSynthesisOptions(speed: 1.1), try VoiceSynthesisOptions(pitch: 1),
                        try VoiceSynthesisOptions(useSSML: true)] {
            do {
                _ = try await synthesize(source, options: options, credential: { try await keys.supply() })
                XCTFail("Unsupported controls were silently ignored")
            } catch { XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedControls) }
        }
        for tuple in [("elevenlabs/unknown", ElevenLabsTTSCatalog.voices[0].providerVoiceID),
                      ("elevenlabs", ElevenLabsTTSCatalog.voices[0].providerVoiceID.lowercased()),
                      ("azure/neural", ElevenLabsTTSCatalog.voices[0].providerVoiceID),
                      ("elevenlabs", "elevenlabs/../../other")] {
            XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: tuple.0, voiceID: tuple.1))
        }
        let huge = try VoiceOutputSourceSnapshot(source: .typedText,
            text: "a" + String(repeating: "\u{301}", count: 40_000))
        do {
            _ = try await synthesize(huge, credential: { try await keys.supply() })
            XCTFail("An oversized indivisible grapheme admitted credentials")
        } catch { XCTAssertEqual(error as? ElevenLabsTTSAPIError, .inputTooLarge) }
        XCTAssertEqual(keys.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertThrowsError(try VoiceOutputSourceSnapshot(source: .typedText, text: " \n "))
    }

    private func voice(
        _ model: ElevenLabsTTSModels.Model = ElevenLabsTTSCatalog.defaultModel
    ) -> DesktopSpeechVoice {
        .elevenlabs(model, ElevenLabsTTSCatalog.voices[0])
    }

    private func wave() throws -> Data {
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000))
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }

    private func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice? = nil,
        options: VoiceSynthesisOptions? = nil,
        credential: @Sendable () async throws -> String = { "synthetic-key" }
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: voice ?? self.voice(), options: options ?? VoiceSynthesisOptions(), credential: credential)
    }
}

extension DesktopElevenLabsSpeechTests {
    func testCancellation_StopsDialogueTransportWithoutFallbackOrPublication() async throws {
        let started = expectation(description: "ElevenLabs admitted")
        let stopped = expectation(description: "ElevenLabs cancelled")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic dialogue cancellation.")
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .typedText, historyRecordID: nil)
        let task = Task {
            try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, voice: self.voice(ElevenLabsTTSModels.elevenV4))
            }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled speech was published")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(capture.records.map(\.outcome), [.cancelled])
        XCTAssertEqual(capture.records.first?.modelID, ElevenLabsTTSModels.elevenV4.desktopModelIdentifier)
    }

    func testInvalidKeysAndForgedQualityTuples_DoNotAdmitHTTPOrNormalizeIntoCanonicalVoices() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic credential refusal.")
        for key in [" \n ", "synthetic\nkey", String(repeating: "x", count: 8_193)] {
            do {
                _ = try await synthesize(source, credential: { key })
                XCTFail("Invalid key admitted")
            } catch {
                XCTAssertEqual(error as? ElevenLabsTTSAPIError,
                               key == " \n " ? .missingCredential : .invalidCredential)
            }
        }
        let forged = ElevenLabsTTSModels.Model(
            id: "eleven_v4", displayName: "Forged model", maximumCharacters: 10_000)
        let keys = CredentialProbe()
        do {
            _ = try await synthesize(source, voice: voice(forged), options: VoiceSynthesisOptions(quality: .highest),
                                     credential: { try await keys.supply() })
            XCTFail("Forged model became canonical")
        } catch { XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedVoice) }
        XCTAssertEqual(keys.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testReadGenerateAndExport_CaptureActualModelGraphemeEstimateAndNoInventedTokens() async throws {
        let audio = try wave()
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "cafe\u{301}")
        for operation in [VoiceSynthesisUsage.Operation.read, .generate, .export] {
            let capture = VoiceSynthesisUsage.Capture(
                operation: operation, source: .clipboard, historyRecordID: UUID())
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
            let record = try XCTUnwrap(capture.records.first)
            XCTAssertEqual(record.operation, operation)
            XCTAssertEqual(record.inputCharacters, 5)
            XCTAssertEqual(record.estimatedCostUSD,
                           Decimal(4) * ElevenLabsTTSAPI.estimatedCostPerThousandCharacters / 1000)
            XCTAssertEqual(try VoiceSynthesisPricing.estimate(for: voice(), text: "  " + source.text + "  "),
                           record.estimatedCostUSD)
            XCTAssertEqual(record.audioDuration, Double(pcm.count) / 48_000)
            XCTAssertNil(record.historyRecordID)
            XCTAssertNil(record.reportedInputTokens)
            XCTAssertEqual(record.outcome, .completed)
        }
    }

    func testLaterSegmentFailure_ReturnsNoPartialWAVAndKeepsBothAttemptRecords() async throws {
        let audio = try wave()
        StubURLProtocol.handler = { request in
            .respond(DeepgramSpeechFixture.response(request),
                     try self.body(request)["text"] as? String == "x" ? Data("bad".utf8) : audio)
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: String(repeating: "x", count: 5_001))
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, voice: self.voice(ElevenLabsTTSModels.elevenV3))
            }
            XCTFail("A partial result was published")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio) }
        XCTAssertEqual(capture.records.map(\.outcome), [.completed, .failed])
    }

    func testCredentialReturnCancellation_StopsBeforeAnyRequestOrUsageAndKeepsCapturedSelection() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic captured.")
        let selected = voice(ElevenLabsTTSModels.elevenV4)
        let selection = try DesktopSpeechSelection(voice: selected, options: VoiceSynthesisOptions())
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .typedText, historyRecordID: nil)
        let task = Task {
            try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, voice: selection.voice, options: selection.options, credential: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return "synthetic-key"
                })
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled speech was returned")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(selection.voice, selected)
        XCTAssertEqual(source.text, "Synthetic captured.")
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertTrue(capture.records.isEmpty)
    }

    func testMacDefaultFormatAndMigrationContracts_AreSharedWithoutChangingItsWireShape() throws {
        let voice = ElevenLabsTTSCatalog.voices[0]
        let request = try ElevenLabsTTSAPI.speechRequest(
            text: "Synthetic Mac.", voiceID: voice.providerVoiceID, modelID: "eleven_multilingual_v2", apiKey: "key")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.elevenlabs.io/v1/text-to-speech/" + voice.id)
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(try body(request).count, 3)
        XCTAssertEqual(ElevenLabsTTSModels.current("eleven_custom_model"), "eleven_custom_model")
        XCTAssertEqual(ElevenLabsTTSModels.current("eleven_turbo_v2"), "eleven_flash_v2_5")
        XCTAssertEqual(ElevenLabsTTSCatalog.voice(forID: "elevenlabs/bella")?.displayName, "Sarah")
    }
}
