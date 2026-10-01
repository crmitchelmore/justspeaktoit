import Foundation
import XCTest

@testable import SpeakCore

final class ModelComparisonExportTests: XCTestCase {
    private func judgedRound() -> ModelComparisonRound {
        var entries = [
            ModelComparisonFixtures.entry("deepgram/nova-3", transcript: "hello there | world"),
            ModelComparisonFixtures.entry("openai/whisper-1", transcript: "hello their world")
        ]
        entries[0].timeToFirstPartialMs = 250
        entries[0].timeToFinalMs = 900
        entries[0].estimatedCostUSD = Decimal(string: "0.0016")
        entries[1].timeToFinalMs = 3_400
        var round = ModelComparisonFixtures.round(entries: entries)
        XCTAssertTrue(round.judge(rankings: [
            ModelComparisonRanking(entryID: entries[1].id, rank: 1),
            ModelComparisonRanking(entryID: entries[0].id, rank: 2)
        ], at: round.createdAt.addingTimeInterval(30)))
        return round
    }

    func testJSON_carriesSchemaVersionRoundsAndScoreboard_withSampleIdentityButNoAudio() throws {
        let round = judgedRound()
        let data = try ModelComparisonExport.json(rounds: [round], exportedAt: round.createdAt)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["schemaVersion"] as? Int, ModelComparisonRound.schemaVersion)
        let rounds = try XCTUnwrap(json["rounds"] as? [[String: Any]])
        XCTAssertEqual(rounds.count, 1)
        let sample = try XCTUnwrap(rounds[0]["sample"] as? [String: Any])
        XCTAssertEqual(sample["contentHash"] as? String, "abc123")
        XCTAssertEqual(sample["name"] as? String, "clip.wav")
        XCTAssertNil(sample["audio"])
        XCTAssertNil(rounds[0]["audioData"])
        let scoreboard = try XCTUnwrap(json["scoreboard"] as? [[String: Any]])
        XCTAssertEqual(scoreboard.first?["modelID"] as? String, "openai/whisper-1", "The winner leads")
        XCTAssertEqual(scoreboard.first?["wins"] as? Int, 1)

        let decoded = try JSONDecoder.iso8601.decode(ModelComparisonExport.Document.self, from: data)
        XCTAssertEqual(decoded.rounds.first?.rankings, round.rankings)
    }

    func testMarkdown_listsEntriesByRankWithLatencyCostAndEscapedTranscripts() {
        let round = judgedRound()
        let markdown = ModelComparisonExport.markdown(round: round)

        XCTAssertTrue(markdown.contains("## Comparison round clip.wav"))
        XCTAssertTrue(markdown.contains("- Input: File"))
        XCTAssertTrue(markdown.contains("sha256 abc123"))
        XCTAssertTrue(markdown.contains("12.5 s"))
        let rows = markdown.split(separator: "\n").filter { $0.hasPrefix("| 1 |") || $0.hasPrefix("| 2 |") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].contains("OPENAI/WHISPER-1"), "Rank 1 row comes first")
        XCTAssertTrue(rows[0].contains("3.4 s"))
        XCTAssertTrue(rows[1].contains("250 ms"))
        XCTAssertTrue(rows[1].contains("$0.0016"))
        XCTAssertTrue(rows[1].contains("hello there \\| world"), "Pipes in transcripts must not break the table")
        XCTAssertTrue(markdown.contains("| Rank | Blind | Model | Provider |"))
    }

    func testMarkdown_forManyRounds_leadsWithTheScoreboard() {
        let round = judgedRound()
        let markdown = ModelComparisonExport.markdown(rounds: [round, round], exportedAt: round.createdAt)

        XCTAssertTrue(markdown.hasPrefix("# Compare Models"))
        XCTAssertTrue(markdown.contains("## Scoreboard"))
        XCTAssertTrue(markdown.contains("| OPENAI/WHISPER-1 | Provider | 2 | 2 | 1.00 |"))
        XCTAssertEqual(markdown.components(separatedBy: "## Comparison round").count - 1, 2)
    }

    func testMarkdownEscapesActiveTranscriptMarkup() {
        let escaped = ModelComparisonExport.escape("![tracking](https://example.test/pixel) <img src='x'> **bold**")
        XCTAssertFalse(escaped.contains("!["))
        XCTAssertTrue(escaped.contains("\\<img"))
        XCTAssertFalse(escaped.contains("**bold**"))
    }

    func testMarkdown_forUnjudgedRound_keepsBlindOrderAndMarksFailures() {
        var entries = [ModelComparisonFixtures.entry("a"), ModelComparisonFixtures.entry("b")]
        entries[1].transcript = ""
        entries[1].errorDescription = "HTTP 401"
        let round = ModelComparisonFixtures.round(entries: entries)

        let markdown = ModelComparisonExport.markdown(round: round)
        XCTAssertTrue(markdown.contains("- Judged: not yet"))
        XCTAssertTrue(markdown.contains("_Failed: HTTP 401_"))
        XCTAssertTrue(markdown.contains("| – | A |"))
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
