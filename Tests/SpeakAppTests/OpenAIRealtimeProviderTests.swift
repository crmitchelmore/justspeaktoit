import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class OpenAIRealtimeProviderTests: XCTestCase {

    // MARK: - Catalogue + capabilities

    func testModelCatalog_includesGPTRealtimeWhisperStreaming() throws {
        let option = try XCTUnwrap(
            ModelCatalog.liveTranscription.first {
                $0.id == "openai/gpt-realtime-whisper-streaming"
            },
            "Expected to find openai/gpt-realtime-whisper-streaming in liveTranscription"
        )

        XCTAssertEqual(option.displayName, "OpenAI GPT Realtime Whisper (Streaming)")
    }

    func testModelCatalog_includesGPTLiveTranscribeStreaming() throws {
        let option = try XCTUnwrap(
            ModelCatalog.liveTranscription.first {
                $0.id == OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID
            }
        )

        XCTAssertEqual(option.displayName, "OpenAI GPT Live Transcribe (Streaming)")
    }

    func testCapabilities_supportsInstantAndLivePolish() {
        let capabilities = ModelCatalog.liveCapabilities(for: "openai/gpt-realtime-whisper-streaming")
        XCTAssertTrue(capabilities.supportedSpeedModes.contains(.instant))
        XCTAssertTrue(capabilities.supportedSpeedModes.contains(.livePolish))
    }

    func testCapabilities_postStopFinalizeBudgetIsSmall() {
        let capabilities = ModelCatalog.liveCapabilities(for: "openai/gpt-realtime-whisper-streaming")
        // Per-segment .completed events arrive during the session, so the
        // post-stop wait should be much smaller than AssemblyAI's 2s.
        XCTAssertGreaterThan(capabilities.postStopFinalizeBudget, 0)
        XCTAssertLessThanOrEqual(capabilities.postStopFinalizeBudget, 1.0)
    }

    func testGPTLiveTranscribeCapabilities_supportLiveModesAndSmallFinalizeBudget() {
        let capabilities = ModelCatalog.liveCapabilities(
            for: OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID
        )

        XCTAssertTrue(capabilities.supportedSpeedModes.contains(.instant))
        XCTAssertTrue(capabilities.supportedSpeedModes.contains(.livePolish))
        XCTAssertGreaterThan(capabilities.postStopFinalizeBudget, 0)
        XCTAssertLessThanOrEqual(capabilities.postStopFinalizeBudget, 1.0)
    }

    // MARK: - Model name translation

    func testRealtimeModelName_stripsStreamingSuffix() {
        let name = OpenAIRealtimeTranscriptionProvider.realtimeModelName(
            from: "openai/gpt-realtime-whisper-streaming"
        )
        XCTAssertEqual(name, "gpt-realtime-whisper")
    }

    func testRealtimeModelName_handlesIDWithoutSuffix() {
        let name = OpenAIRealtimeTranscriptionProvider.realtimeModelName(
            from: "openai/gpt-realtime-whisper"
        )
        XCTAssertEqual(name, "gpt-realtime-whisper")
    }

    func testRealtimeModelName_mapsGPTLiveTranscribeCatalogID() {
        let name = OpenAIRealtimeTranscriptionProvider.realtimeModelName(
            from: OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID
        )

        XCTAssertEqual(name, OpenAITranscriptionModels.gptLiveTranscribeAPIName)
    }

    // MARK: - Shared event parser (the adapter delegates to SpeakCore)

    func testParser_decodesSessionCreatedAsSessionCreatedNotReady() {
        let json = """
        {"type":"transcription_session.created","session":{"id":"sess_1"}}
        """
        // `created` is informational only — readiness must wait for `updated`,
        // which acknowledges *our* session.update payload.
        XCTAssertEqual(OpenAIRealtimeServerEvent.parse(json), .sessionCreated)
    }

    func testParser_decodesSessionUpdatedAsSessionReady() {
        let json = #"{"type":"transcription_session.updated"}"#
        XCTAssertEqual(OpenAIRealtimeServerEvent.parse(json), .sessionUpdated(sessionType: nil))
    }

    func testParser_decodesTranscriptionDelta() {
        let json = """
        {"type":"conversation.item.input_audio_transcription.delta",\
        "item_id":"item_42","delta":"hello"}
        """
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(json),
            .transcriptionDelta(itemID: "item_42", delta: "hello")
        )
    }

    func testParser_dropsEmptyDelta() {
        let json = """
        {"type":"conversation.item.input_audio_transcription.delta",\
        "item_id":"item_1","delta":""}
        """
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(json),
            .ignored(type: "conversation.item.input_audio_transcription.delta")
        )
    }

    func testParser_decodesTranscriptionCompleted() {
        let json = """
        {"type":"conversation.item.input_audio_transcription.completed",\
        "item_id":"item_42","transcript":"Hello there."}
        """
        XCTAssertEqual(
            OpenAIRealtimeServerEvent.parse(json),
            .transcriptionCompleted(itemID: "item_42", transcript: "Hello there.")
        )
    }

    func testParser_decodesServerErrorIntoErrorOutcome() {
        let json = """
        {"type":"error","error":{"code":"invalid_request_error","message":"bad audio format"}}
        """
        guard case .error(let code, let message, let eventID)? = OpenAIRealtimeServerEvent.parse(json) else {
            return XCTFail("Expected an error event")
        }
        XCTAssertNil(eventID)
        let description = OpenAIRealtimeStreamingError.serverError(code: code, message: message).localizedDescription
        XCTAssertTrue(description.contains("invalid_request_error"))
        XCTAssertTrue(description.contains("bad audio format"))
    }

    func testParser_ignoresUnknownEventType() {
        let json = #"{"type":"response.audio.delta","data":"..."}"#
        XCTAssertEqual(OpenAIRealtimeServerEvent.parse(json), .ignored(type: "response.audio.delta"))
    }

    func testParser_handlesGarbageJSONWithoutCrashing() {
        XCTAssertNil(OpenAIRealtimeServerEvent.parse("not json"))
        XCTAssertNil(OpenAIRealtimeServerEvent.parse("{}"))
    }

    // MARK: - Adapter

    func testTranscriber_exposesTheSharedCanonicalEvents() {
        // The controller pattern-matches these cases; the adapter must keep
        // exposing the shared event type rather than a platform copy.
        let event: OpenAIRealtimeLiveTranscriber.Event = .delta("hello", itemId: "item_1")
        XCTAssertEqual(event, OpenAIRealtimeLiveClient.Event.delta("hello", itemId: "item_1"))
    }
}
