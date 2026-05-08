import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class OpenAIRealtimeProviderTests: XCTestCase {

    // MARK: - Catalogue + capabilities

    func testModelCatalog_includesGPTRealtimeWhisperStreaming() {
        let ids = ModelCatalog.liveTranscription.map(\.id)
        XCTAssertTrue(
            ids.contains("openai/gpt-realtime-whisper-streaming"),
            "OpenAI gpt-realtime-whisper-streaming must be registered in ModelCatalog.liveTranscription"
        )
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

    // MARK: - Event parser

    func testParser_decodesSessionCreatedAsSessionCreatedNotReady() {
        let json = """
        {"type":"transcription_session.created","session":{"id":"sess_1"}}
        """
        let outcomes = OpenAIRealtimeEventParser.parse(json)
        XCTAssertEqual(outcomes.count, 1)
        // `created` is informational only — readiness must wait for `updated`,
        // which acknowledges *our* transcription_session.update payload.
        guard case .event(.sessionCreated) = outcomes.first else {
            return XCTFail("Expected .sessionCreated event, got \(outcomes)")
        }
    }

    func testParser_decodesSessionUpdatedAsSessionReady() {
        let json = #"{"type":"transcription_session.updated"}"#
        let outcomes = OpenAIRealtimeEventParser.parse(json)
        guard case .event(.sessionReady) = outcomes.first else {
            return XCTFail("Expected .sessionReady event, got \(outcomes)")
        }
    }

    func testParser_decodesTranscriptionDelta() {
        let json = """
        {"type":"conversation.item.input_audio_transcription.delta",\
        "item_id":"item_42","delta":"hello"}
        """
        let outcomes = OpenAIRealtimeEventParser.parse(json)
        guard case .event(.delta(let text, let itemId)) = outcomes.first else {
            return XCTFail("Expected .delta event, got \(outcomes)")
        }
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(itemId, "item_42")
    }

    func testParser_dropsEmptyDelta() {
        let json = """
        {"type":"conversation.item.input_audio_transcription.delta",\
        "item_id":"item_1","delta":""}
        """
        let outcomes = OpenAIRealtimeEventParser.parse(json)
        guard case .ignored = outcomes.first else {
            return XCTFail("Expected .ignored for empty delta, got \(outcomes)")
        }
    }

    func testParser_decodesTranscriptionCompleted() {
        let json = """
        {"type":"conversation.item.input_audio_transcription.completed",\
        "item_id":"item_42","transcript":"Hello there."}
        """
        let outcomes = OpenAIRealtimeEventParser.parse(json)
        guard case .event(.completed(let transcript, let itemId)) = outcomes.first else {
            return XCTFail("Expected .completed event, got \(outcomes)")
        }
        XCTAssertEqual(transcript, "Hello there.")
        XCTAssertEqual(itemId, "item_42")
    }

    func testParser_decodesServerErrorIntoErrorOutcome() {
        let json = """
        {"type":"error","error":{"code":"invalid_request_error","message":"bad audio format"}}
        """
        let outcomes = OpenAIRealtimeEventParser.parse(json)
        guard case .error(let error) = outcomes.first else {
            return XCTFail("Expected .error outcome, got \(outcomes)")
        }
        let description = error.localizedDescription
        XCTAssertTrue(description.contains("invalid_request_error"))
        XCTAssertTrue(description.contains("bad audio format"))
    }

    func testParser_ignoresUnknownEventType() {
        let json = #"{"type":"response.audio.delta","data":"..."}"#
        let outcomes = OpenAIRealtimeEventParser.parse(json)
        guard case .ignored = outcomes.first else {
            return XCTFail("Expected .ignored for unknown event, got \(outcomes)")
        }
    }

    func testParser_handlesGarbageJSONWithoutCrashing() {
        XCTAssertEqual(OpenAIRealtimeEventParser.parse("not json").count, 0)
        XCTAssertEqual(OpenAIRealtimeEventParser.parse("{}").count, 0)
    }
}
