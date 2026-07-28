import Foundation
import XCTest

@testable import SpeakCore

final class OpenAITranscriptionModelsTests: XCTestCase {
    func testIdentifiers_mapCatalogModelsToOpenAIAPINames() {
        XCTAssertEqual(
            OpenAITranscriptionModels.apiModelName(
                from: OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID
            ),
            "gpt-live-transcribe"
        )
        XCTAssertEqual(
            OpenAITranscriptionModels.apiModelName(
                from: OpenAITranscriptionModels.gptTranscribeCatalogID
            ),
            "gpt-transcribe"
        )
    }

    func testLanguageFields_preserveEachModelFamilyWireContract() {
        XCTAssertEqual(
            OpenAITranscriptionModels.batchLanguageFieldName(for: "gpt-transcribe"),
            "languages[]"
        )
        XCTAssertEqual(
            OpenAITranscriptionModels.batchLanguageFieldName(for: "gpt-4o-transcribe"),
            "language"
        )
    }

    func testRealtimePayload_gptLiveTranscribeUsesLanguagesAndPrompt() throws {
        let input = try realtimeInput(
            model: "gpt-live-transcribe",
            language: "en",
            prompt: "Just Speak to It, OpenAI"
        )
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])

        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(transcription["languages"] as? [String], ["en"])
        XCTAssertNil(transcription["language"])
        XCTAssertEqual(transcription["prompt"] as? String, "Just Speak to It, OpenAI")
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func testRealtimePayload_existingModelsKeepSingularLanguageAndPromptRules() throws {
        let gpt4oInput = try realtimeInput(
            model: "gpt-4o-transcribe",
            language: "en",
            prompt: "Just Speak to It"
        )
        let gpt4o = try XCTUnwrap(gpt4oInput["transcription"] as? [String: Any])
        XCTAssertEqual(gpt4o["language"] as? String, "en")
        XCTAssertNil(gpt4o["languages"])
        XCTAssertEqual(gpt4o["prompt"] as? String, "Just Speak to It")

        let whisperInput = try realtimeInput(
            model: "gpt-realtime-whisper",
            language: "en",
            prompt: "This field is unsupported"
        )
        let whisper = try XCTUnwrap(whisperInput["transcription"] as? [String: Any])
        XCTAssertEqual(whisper["language"] as? String, "en")
        XCTAssertNil(whisper["prompt"])
    }

    private func realtimeInput(
        model: String,
        language: String?,
        prompt: String?
    ) throws -> [String: Any] {
        let payload = OpenAITranscriptionModels.realtimeSessionUpdatePayload(
            model: model,
            language: language,
            prompt: prompt,
            sampleRate: 24_000
        )
        XCTAssertEqual(payload["type"] as? String, "session.update")
        let session = try XCTUnwrap(payload["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        return try XCTUnwrap(audio["input"] as? [String: Any])
    }
}
