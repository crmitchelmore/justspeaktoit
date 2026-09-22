import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

final class OpenAIRealtimeProtocolTests: XCTestCase {
    func testParserDecodesGAAndLegacyEventNames() {
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(#"{"type":"transcription_session.created","session":{"id":"s"}}"#),
            .sessionCreated
        )
        XCTAssertEqual(OpenAIRealtimeServerEvent.parse(#"{"type":"session.created"}"#), .sessionCreated)
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(#"{"type":"transcription_session.updated"}"#),
            .sessionUpdated(sessionType: nil)
        )
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(#"{"type":"session.updated","session":{"type":"transcription"}}"#),
            .sessionUpdated(sessionType: "transcription")
        )
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(
                #"{"type":"input_audio_buffer.committed","item_id":"item_2","previous_item_id":"item_1"}"#
            ),
            .inputAudioBufferCommitted(itemID: "item_2", previousItemID: "item_1")
        )
    }

    func testParserDecodesTranscriptionEventsAndDropsEmptyDeltas() {
        let delta = #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_42","delta":"hello"}"#
        XCTAssertEqual(OpenAIRealtimeServerEvent.parse(delta), .transcriptionDelta(itemID: "item_42", delta: "hello"))
        let empty = #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_1","delta":""}"#
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(empty),
            .ignored(type: "conversation.item.input_audio_transcription.delta")
        )
        let completed = #"{"type":"conversation.item.input_audio_transcription.completed","#
            + #""item_id":"item_42","transcript":"Hello there."}"#
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(completed),
            .transcriptionCompleted(itemID: "item_42", transcript: "Hello there.")
        )
        let failed = #"{"type":"conversation.item.input_audio_transcription.failed","item_id":"item_9","#
            + #""error":{"code":"audio_unintelligible","message":"Could not transcribe"}}"#
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(failed),
            .transcriptionFailed(itemID: "item_9", code: "audio_unintelligible", message: "Could not transcribe")
        )
    }

    func testParserDecodesErrorsIgnoresUnknownTypesAndRejectsGarbage() {
        let error = #"{"type":"error","error":{"code":"invalid_request_error","message":"bad audio format"}}"#
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(error),
            .error(code: "invalid_request_error", message: "bad audio format")
        )
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(#"{"type":"error","message":"top level"}"#),
            .error(code: "unknown", message: "top level")
        )
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(#"{"type":"response.audio.delta","data":"..."}"#),
            .ignored(type: "response.audio.delta")
        )
        XCTAssertNil(OpenAIRealtimeServerEvent.parse("not json"))
        XCTAssertNil(OpenAIRealtimeServerEvent.parse("{}"))
        let description = OpenAIRealtimeStreamingError.serverError(
            code: "invalid_request_error", message: "bad audio format"
        ).localizedDescription
        XCTAssertTrue(description.contains("invalid_request_error"))
        XCTAssertTrue(description.contains("bad audio format"))
    }

    func testRequestFramingAndAudioConstantsMatchTheGAContract() throws {
        let request = try XCTUnwrap(OpenAIRealtimeProtocol.webSocketRequest(apiKey: "sk-test"))
        XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/realtime?intent=transcription")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))
        XCTAssertEqual(OpenAIRealtimeProtocol.sampleRate, 24_000)
        XCTAssertEqual(OpenAIRealtimeProtocol.bytesPerSecond, 48_000)
        XCTAssertEqual(OpenAIRealtimeProtocol.minimumCommitBytes, 4_800)
        XCTAssertEqual(LiveTranscriptionProviderID.openai.expectedSampleRate, OpenAIRealtimeProtocol.sampleRate)
        let pcm = Data((0..<600).map { UInt8($0 % 251) })
        let append = OpenAIRealtimeProtocol.appendJSON(pcm16: pcm)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(append.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(object["audio"] as? String)), pcm)
        let commit = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(OpenAIRealtimeProtocol.commitJSON.utf8)) as? [String: Any]
        )
        XCTAssertEqual(commit["type"] as? String, "input_audio_buffer.commit")
    }

    func testSessionUpdateReusesTheSharedPayloadBuilder() throws {
        let json = try XCTUnwrap(OpenAIRealtimeProtocol.sessionUpdateJSON(
            model: "openai/gpt-transcribe", language: "fr", prompt: "Context", sampleRate: 24_000
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let expected = OpenAITranscriptionModels.realtimeSessionUpdatePayload(
            model: "openai/gpt-transcribe", language: "fr", prompt: "Context", sampleRate: 24_000
        )
        XCTAssertEqual(object as NSDictionary, expected as NSDictionary)
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-transcribe")
        XCTAssertEqual(transcription["languages"] as? [String], ["fr"])
        XCTAssertEqual(transcription["prompt"] as? String, "Context")
    }

    func testFinaliseBudgetFollowsTheCatalogueForEveryOpenAILiveRoute() {
        let routes = LiveTranscriptionRouting.allRoutes.filter { $0.provider == .openai }
        XCTAssertFalse(routes.isEmpty)
        for route in routes {
            XCTAssertEqual(
                OpenAIRealtimeLiveClient.finalizeBudget(forModel: route.apiModelName),
                ModelCatalog.liveCapabilities(for: route.modelID).postStopFinalizeBudget,
                route.modelID
            )
            XCTAssertGreaterThan(OpenAIRealtimeLiveClient.finalizeBudget(forModel: route.modelID), 0)
        }
        XCTAssertEqual(
            OpenAIRealtimeLiveClient.finalizeBudget(forModel: "gpt-future-transcribe"),
            ModelCatalog.liveCapabilities(
                for: OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID
            ).postStopFinalizeBudget
        )
    }

    func testAssemblerOrdersByFirstSightingAndTreatsCompletionsAsAuthoritative() {
        var assembler = OpenAIRealtimeTranscriptAssembler()
        assembler.noteCommitted(itemKey: "item_b")
        XCTAssertEqual(assembler.consume(delta: " Hel", itemID: "item_a"), "Hel")
        XCTAssertEqual(assembler.consume(delta: "lo", itemID: "item_a"), "Hello")
        XCTAssertEqual(assembler.consume(delta: "world", itemID: "item_b"), "world Hello")
        XCTAssertEqual(assembler.consume(completed: "World.", itemID: "item_b"), "World. Hello")
        XCTAssertEqual(assembler.consume(delta: " again", itemID: "item_b"), "World. Hello",
                       "Deltas after the authoritative completion are ignored")
        XCTAssertEqual(assembler.consume(completed: "", itemID: "item_a"), "World.",
                       "An empty completion replaces the item's deltas")
        XCTAssertEqual(assembler.consume(delta: "tail", itemID: ""), "World. tail")
        XCTAssertEqual(assembler.consume(completed: "Tail.", itemID: ""), "World. Tail.")
        XCTAssertEqual(
            assembler.completedItemKeys,
            ["item_a", "item_b", OpenAIRealtimeTranscriptAssembler.pendingItemKey]
        )
        XCTAssertEqual(assembler.transcriptOrNil, "World. Tail.")
        XCTAssertNil(OpenAIRealtimeTranscriptAssembler().transcriptOrNil)
    }
}
