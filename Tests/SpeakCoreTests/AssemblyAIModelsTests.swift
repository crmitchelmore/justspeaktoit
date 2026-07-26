import Foundation
@testable import SpeakCore
import XCTest

final class AssemblyAIModelsTests: XCTestCase {
    func testStreamingURL_usesUniversal35ProWithoutRetiredParameters() throws {
        let url = try XCTUnwrap(AssemblyAIStreamingRequest.url(
            endpoint: .europe,
            apiKey: "test-key",
            sampleRate: 16_000,
            keyterms: ["AssemblyAI", "Universal-3.5 Pro"]
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(url.host, AssemblyAIStreamingEndpoint.europe.rawValue)
        XCTAssertEqual(query["speech_model"], AssemblyAIModels.universal35ProAPIName)
        XCTAssertEqual(query["sample_rate"], "16000")
        XCTAssertEqual(query["min_turn_silence"], "560")
        XCTAssertNil(query["format_turns"])
        XCTAssertNil(query["language_detection"])
        XCTAssertNil(query["language"])
        XCTAssertNil(query["end_of_turn_confidence_threshold"])

        let keyterms = try XCTUnwrap(query["keyterms_prompt"])
        let data = Data(keyterms.utf8)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: data), ["AssemblyAI", "Universal-3.5 Pro"])
    }

    func testStreamingURL_filtersInvalidKeytermsAndCapsAtOneHundred() throws {
        let valid = (0..<105).map { "term-\($0)" }
        let url = try XCTUnwrap(AssemblyAIStreamingRequest.url(
            endpoint: .global,
            apiKey: "test-key",
            sampleRate: 16_000,
            keyterms: ["", String(repeating: "x", count: 51)] + valid
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let encoded = try XCTUnwrap(components.queryItems?.first { $0.name == "keyterms_prompt" }?.value)

        let decoded = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
        XCTAssertEqual(decoded.count, 100)
        XCTAssertEqual(decoded.first, "term-0")
        XCTAssertEqual(decoded.last, "term-99")
    }

    func testTranscriptAssembler_commitsSingleFormattedEndOfTurn() throws {
        var assembler = AssemblyAIStreamingTranscriptAssembler()
        let partial = try decodeTurn(
            #"{"type":"Turn","turn_order":0,"turn_is_formatted":false,"end_of_turn":false,"transcript":"hello wor"}"#
        )
        let final = try decodeTurn(
            #"{"type":"Turn","turn_order":0,"turn_is_formatted":true,"end_of_turn":true,"transcript":"Hello world."}"#
        )

        XCTAssertEqual(
            assembler.consume(partial),
            AssemblyAIStreamingTranscriptUpdate(displayText: "hello wor", finalizedTurn: false)
        )
        XCTAssertEqual(
            assembler.consume(final),
            AssemblyAIStreamingTranscriptUpdate(displayText: "Hello world.", finalizedTurn: true)
        )

        let nextPartial = try decodeTurn(
            #"{"type":"Turn","turn_order":1,"turn_is_formatted":false,"end_of_turn":false,"transcript":"Next"}"#
        )
        XCTAssertEqual(
            assembler.consume(nextPartial),
            AssemblyAIStreamingTranscriptUpdate(displayText: "Hello world. Next", finalizedTurn: false)
        )
    }

    func testTranscriptAssembler_doesNotCommitUnformattedEndOfTurn() throws {
        var assembler = AssemblyAIStreamingTranscriptAssembler()
        let legacyFinal = try decodeTurn(
            #"{"turn_order":0,"turn_is_formatted":false,"end_of_turn":true,"transcript":"legacy final"}"#
        )

        XCTAssertEqual(
            assembler.consume(legacyFinal),
            AssemblyAIStreamingTranscriptUpdate(displayText: "legacy final", finalizedTurn: false)
        )
    }

    private func decodeTurn(_ json: String) throws -> AssemblyAIStreamingTurn {
        try JSONDecoder().decode(AssemblyAIStreamingTurn.self, from: Data(json.utf8))
    }
}
