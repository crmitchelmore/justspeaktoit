import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// The October 2026 public-preview models must use the direct Mistral
/// contracts without changing a user's existing pinned selections.
final class Voxtral3ModelTests: DeepgramSpeechStubTestCase {
    func testBatchChoices_KeepDirectCredentialsPublishedRatesAndSavedIDs() throws {
        let models = [
            (MistralVoxtral3.miniBatchID, "mistral/voxtral-mini-transcribe-3-0", "0.0035"),
            (MistralVoxtral3.smallBatchID, "mistral/voxtral-small-transcribe-3-0", "0.004")
        ]
        let providerIDs = Set(ModelCatalog.batchTranscriptionOptions(forProvider: "mistral").map(\.id))
        for (identifier, expectedID, price) in models {
            XCTAssertEqual(identifier, expectedID)
            let option = try XCTUnwrap(ModelCatalog.batchTranscription.first { $0.id == identifier })
            XCTAssertTrue(option.displayName.contains("3"))
            XCTAssertTrue(providerIDs.contains(identifier))
            XCTAssertEqual(ModelCatalog.normalizedBatchTranscriptionModel(identifier), identifier)
            XCTAssertEqual(ModelCredentialResolver.requirement(for: identifier, purpose: .batchTranscription),
                           .apiKey(identifier: "mistral.apiKey", providerName: "Mistral"))
            XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: identifier), Decimal(string: price))
            XCTAssertFalse(ModelCatalog.liveTranscription.contains { $0.id == identifier })
        }
        XCTAssertTrue(providerIDs.contains("mistral/voxtral-mini-latest"))
        XCTAssertEqual(ModelCatalog.normalizedBatchTranscriptionModel("mistral/voxtral-mini-latest"),
                       "mistral/voxtral-mini-latest")
    }

    func testRealtimeChoice_RoutesThePinnedModelAcrossPlatformsWithAnExplicitFinishBudget() throws {
        let identifier = MistralVoxtral3.realtimeID
        XCTAssertEqual(identifier, "mistral/voxtral-mini-transcribe-realtime-3-0-streaming")
        XCTAssertTrue(ModelCatalog.liveTranscriptionOptions(forProvider: "mistral").contains { $0.id == identifier })
        XCTAssertFalse(ModelCatalog.batchTranscription.contains { $0.id == identifier })
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: identifier))
        XCTAssertEqual(route.provider, .mistral)
        XCTAssertEqual(route.apiModelName, "voxtral-mini-transcribe-realtime-3-0")
        XCTAssertEqual(route.apiModelName, MistralVoxtral3.realtimeAPIModelID)
        XCTAssertEqual(route.apiKeyIdentifier, "mistral.apiKey")
        XCTAssertTrue(route.isSupportedOnIOS)
        XCTAssertEqual(ModelCredentialResolver.requirement(for: identifier, purpose: .liveTranscription),
                       .apiKey(identifier: "mistral.apiKey", providerName: "Mistral"))
        XCTAssertEqual(TranscriptionPricing.pricePerMinuteUSD(modelID: identifier), Decimal(string: "0.008"))
        XCTAssertEqual(ModelCatalog.normalizedLiveTranscriptionModel(identifier), identifier)
        let capabilities = ModelCatalog.liveCapabilities(for: identifier)
        XCTAssertEqual(capabilities.postStopFinalizeBudget, MistralVoxtralRealtime.finishBudget)
        XCTAssertTrue(capabilities.supportedSpeedModes.contains(.instant))
        XCTAssertTrue(capabilities.supportedSpeedModes.contains(.livePolish))
        XCTAssertFalse(capabilities.supportsLanguageHint, "The host does not yet forward the v3 language option")
        XCTAssertEqual(ModelCatalog.normalizedLiveTranscriptionModel(MistralVoxtralRealtime.liveCatalogID),
                       MistralVoxtralRealtime.liveCatalogID)
    }

    func testKeywordCapabilities_AcceptBothNewBatchModelsWithoutEnablingUnknownOrRealtimeModels() {
        for identifier in [MistralVoxtral3.miniBatchID, MistralVoxtral3.smallBatchID] {
            XCTAssertTrue(MistralBatchClient.supportsKeywords(model: identifier))
            let apiID = identifier.split(separator: "/").last.map(String.init) ?? identifier
            XCTAssertTrue(MistralBatchClient.supportsKeywords(model: apiID))
        }
        XCTAssertTrue(MistralBatchClient.supportsKeywords(model: "mistral/voxtral-mini-latest"))
        XCTAssertFalse(MistralBatchClient.supportsKeywords(model: "mistral/custom"))
        XCTAssertFalse(MistralBatchClient.supportsKeywords(model: MistralVoxtral3.realtimeAPIModelID))
    }

    func testRealtime3Finish_DrainsAllAudioThenEndsWithoutLegacyFlush() async throws {
        let socket = CartesiaTestSocket()
        let client = MistralVoxtralLiveClient(
            apiKey: "fixture-key", model: MistralVoxtral3.realtimeAPIModelID,
            makeConnection: { _ in socket })
        defer { client.cancel() }
        let ended = expectation(description: "All audio drained before end")
        socket.onSend { message in
            if case .text(let text) = message, text == MistralVoxtralLiveClient.endFrame { ended.fulfill() }
        }
        client.start(onTranscript: { _, _ in }, onError: { XCTFail("Unexpected failure: \($0)") })
        socket.open()
        socket.emit(#"{"type":"session.created"}"#)
        socket.completeSend() // Configuration.
        client.sendAudio(Data(repeating: 1, count: 3_200))
        client.sendAudio(Data(repeating: 2, count: 3_200))
        socket.completeSend() // First append; second is still in flight.
        let finish = Task { await client.finishAndWait() }
        XCTAssertFalse(socket.texts.contains(MistralVoxtralLiveClient.endFrame))
        socket.completeSend() // Last append releases end.
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertFalse(socket.texts.contains(MistralVoxtralLiveClient.flushFrame))
        let types = try socket.texts.map { text in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            return try XCTUnwrap(object["type"] as? String)
        }
        XCTAssertEqual(types, ["session.update", "input_audio.append", "input_audio.append", "input_audio.end"])
        // The service may reply before end's transport completion. All PCM
        // has drained, so this final must still complete the session.
        XCTAssertEqual(socket.pendingCompletions, 1)
        socket.emit(#"{"type":"transcription.done","text":"Complete recording."}"#)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Complete recording.")
    }

    func testRealtime3DoneBeforeEnd_ReportsUnconfirmedAudioInsteadOfSuccess() async {
        let socket = CartesiaTestSocket()
        let client = MistralVoxtralLiveClient(
            apiKey: "fixture-key", model: MistralVoxtral3.realtimeAPIModelID,
            makeConnection: { _ in socket })
        defer { client.cancel() }
        let failed = expectation(description: "Premature done rejected")
        client.start(onTranscript: { _, _ in }, onError: { error in
            XCTAssertEqual(error as? MistralRealtimeStreamingError, .unexpectedCompletion)
            failed.fulfill()
        })
        socket.open()
        socket.emit(#"{"type":"session.created"}"#)
        socket.completeSend()
        client.sendAudio(Data(repeating: 1, count: 3_200))
        // Done during an outstanding append cannot acknowledge the recording.
        socket.emit(#"{"type":"transcription.done","text":"Recovery text."}"#)
        await fulfillment(of: [failed], timeout: 2)
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Recovery text.")
        XCTAssertFalse(socket.texts.contains(MistralVoxtralLiveClient.endFrame))
    }

    func testExplicitTTS3Request_PreservesTheSelectedVoiceAndFormatThroughTheTransport() async throws {
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        let payload = try JSONSerialization.data(withJSONObject: ["audio_data": audio.base64EncodedString()])
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url, MistralTTSAPI.speechEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(
                with: StubURLProtocol.body(of: request)) as? [String: Any])
            XCTAssertEqual(fields["model"] as? String, "voxtral-mini-tts-3-0")
            XCTAssertEqual(fields["voice_id"] as? String, "gb_jane_neutral")
            XCTAssertEqual(fields["response_format"] as? String, "wav")
            XCTAssertEqual(fields["input"] as? String, "A selected voice remains selected.")
            XCTAssertEqual(fields["stream"] as? Bool, false)
            return .respond(DeepgramSpeechFixture.response(request), payload)
        }
        let result = try await MistralTTSAPI(session: session).synthesize(
            input: "A selected voice remains selected.", apiKey: "fixture-key",
            request: MistralTTSRequest(
                model: .voxtralMiniTTS3, voiceID: "mistral/gb_jane_neutral", responseFormat: .wav))
        XCTAssertEqual(result, audio)
        XCTAssertTrue(MistralTTSCatalog.models.contains(.voxtralMiniTTS3))
        XCTAssertEqual(MistralTTSCatalog.defaultModel, .voxtralMiniTTS2603)
        XCTAssertEqual(MistralTTSRequest(voiceID: "legacy").model.rawValue, "voxtral-mini-tts-2603")
        XCTAssertEqual(MistralTTSAPI.estimatedCostPerThousandCharacters, Decimal(string: "0.016"))
    }
}
