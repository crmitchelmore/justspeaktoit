import Foundation
import XCTest
@testable import SpeakCore
import SpeakDesktop

final class DesktopKeywordDeliveryTests: XCTestCase {
    func testCanonicalParsingDoesNotApplyMetasLimitsToOtherProviders() throws {
        let long = String(repeating: "a", count: 101)
        let words = ["Speak", long] + (0..<110).map { "term\($0)" }
        let configuration = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string(
                " Speak,\n speak, , " + words.dropFirst().joined(separator: ",")
            ))
        ])
        XCTAssertEqual(configuration.liveOptions.keywords, words)
        XCTAssertEqual(configuration.liveOptions.assemblyAIKeyterms, words)
        XCTAssertEqual(TranscriptionKeywordPolicy.words(from: " , \n"), [])
        XCTAssertTrue(try DesktopConfiguration().liveOptions.keywords.isEmpty)
    }

    func testClearAndRecoveredWordsNeverBecomeActiveHintsWithoutRecovery() throws {
        let configuration = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("")),
            "assemblyAIKeyterms": AnyCodable(.string("Competing edit")),
            "transcriptionKeywordsLastReconciled": AnyCodable(.string("Original"))
        ])
        XCTAssertTrue(configuration.liveOptions.keywords.isEmpty)
        XCTAssertTrue(configuration.liveOptions.assemblyAIKeyterms.isEmpty)
        XCTAssertNil(TranscriptionKeywordPolicy.prompt(configuration.liveOptions.keywords))
        XCTAssertEqual(try configuration.recoveringKeywords("Competing edit").liveOptions.keywords, ["Competing edit"])
    }

    func testGlossaryAndProviderBoundsAreStableAndUnicodeByteBounded() throws {
        XCTAssertEqual(TranscriptionKeywordPolicy.prompt([" Speak ", "speak", "Grace"]), "Speak, Grace")
        XCTAssertNil(TranscriptionKeywordPolicy.prompt([]))
        let unicode = Array(repeating: String(repeating: "\u{754c}", count: 100), count: 120)
        XCTAssertNil(TranscriptionKeywordPolicy.prompt(unicode))
        let deepgram = TranscriptionKeywordPolicy.deepgramQuery(
            model: "nova-3", words: (0..<120).map { "\($0)" + String(repeating: "a", count: 90) }
        )
        XCTAssertLessThanOrEqual(deepgram.reduce(0) { $0 + ($1.value?.utf8.count ?? 0) + 1 }, 500)
        XCTAssertTrue(deepgram.allSatisfy { $0.name == "keyterm" })
        XCTAssertEqual(
            TranscriptionKeywordPolicy.deepgramQuery(model: "nova-2", words: ["Speak"]).first?.name, "keywords"
        )
        XCTAssertTrue(TranscriptionKeywordPolicy.deepgramQuery(model: "unknown", words: ["Speak"]).isEmpty)
    }

    func testScribeOnlyAcceptsLegalShortTermsAndAvoidsTheOver100BillingThreshold() {
        let words = ["Speak", "speak", "<term>", "one two three four five six", String(repeating: "x", count: 50)]
            + (0..<120).map { "term\($0)" }
        let result = ElevenLabsLiveProtocol.boundedKeyterms(words)
        XCTAssertEqual(result.count, 100)
        XCTAssertEqual(result.first, "Speak")
        XCTAssertFalse(result.contains("<term>"))
        XCTAssertFalse(result.contains(String(repeating: "x", count: 50)))
    }

    func testGlossarySkipsIndividuallyOversizedUTF8TermsBeforeCountAndBudget() {
        let oversized = String(repeating: "\u{754c}", count: 100)
        XCTAssertEqual(TranscriptionKeywordPolicy.prompt([oversized, "Speak"]), "Speak")
        XCTAssertEqual(TranscriptionKeywordPolicy.prompt(["First", oversized, "Second"]), "First, Second")
        XCTAssertEqual(
            TranscriptionKeywordPolicy.prompt(Array(repeating: oversized, count: 101) + ["Speak", "speak"]), "Speak"
        )
        let prefix = String(repeating: "a", count: 220)
        XCTAssertEqual(TranscriptionKeywordPolicy.prompt([prefix, "Speak", "X"]), prefix)
    }

    func testProfileCapturesIndependentProviderOptionsAndAnExplicitEmptySnapshot() {
        let original = DesktopProfileSession.defaults(
            modelIdentifier: "openai/gpt-4o-transcribe", postProcessing: .init(), language: "fr"
        )
        let captured = original.capturingTranscriptionOptions(.init(
            keywords: ["Global"], assemblyAIKeyterms: ["Explicit override"]
        ))
        XCTAssertNil(original.transcriptionKeywords)
        XCTAssertEqual(captured.transcriptionKeywords, ["Global"])
        XCTAssertEqual(captured.transcriptionOptions?.assemblyAIKeyterms, ["Explicit override"])
        XCTAssertEqual(captured.language, original.language)
        XCTAssertEqual(captured.postProcessing, original.postProcessing)
        XCTAssertEqual(original.capturingTranscriptionOptions(.init()).transcriptionKeywords, [])
    }

    func testUnqualifiedAndAnnotationIncompatibleRoutesHaveExplicitLimitations() {
        XCTAssertNotNil(DesktopTranscription.keywordLimitation(model: "openai/gpt-4o-transcribe-diarize"))
        XCTAssertNotNil(DesktopTranscription.keywordLimitation(model: "mistral/voxtral-mini-transcribe-realtime-2602"))
        XCTAssertNotNil(DesktopTranscription.keywordLimitation(model: CartesiaBatchClient.catalogID))
        for model in GeminiTranscribeModels.directBatchModelIDs {
            XCTAssertTrue(DesktopTranscription.keywordLimitation(model: model)?.contains("diarization") == true)
        }
        XCTAssertNil(DesktopTranscription.keywordLimitation(model: "openai/gpt-4o-transcribe"))
        XCTAssertNil(DesktopTranscription.keywordLimitation(model: "groq/whisper-large-v3-turbo"))
    }
}
