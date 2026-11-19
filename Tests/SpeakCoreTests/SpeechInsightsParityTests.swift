import Foundation
import XCTest

@testable import SpeakCore

/// `Tests/Fixtures/speech-insights/parity.json` is shared with Android's `SpeechInsightsParityTest`:
/// both read the same sessions and History entries and must produce the `expected` numbers, so the
/// iPhone, Mac and Android dashboards agree for the same history. Regenerate `expected` after a
/// deliberate SpeakCore change with
/// `UPDATE_SPEECH_INSIGHTS_PARITY=1 swift test --filter SpeechInsightsParityTests`.
private struct ParitySession: Codable {
    let id: UUID
    let startedAt: Date
    let durationSeconds: Double
    let text: String
}

/// One History entry for the usage totals; `text` is the cleaned text.
private struct ParityUsageEntry: Codable {
    let text: String
    let rawText: String?
    let durationSeconds: Double?
    let failed: Bool
}

private struct ParityFixture: Codable {
    let sessions: [ParitySession]
    let usageEntries: [ParityUsageEntry]
    var expected: ParityExpected?
}

private struct ParityTerm: Codable, Equatable {
    let term: String
    let count: Int
}

private struct ParityWeek: Codable, Equatable {
    let weekStart: String
    let totalWords: Int
    let fillerCount: Int
}

private struct ParityBucket: Codable, Equatable {
    let label: String
    let count: Int
}

private struct ParityPace: Codable, Equatable {
    let averageWPM: Double
    let medianWPM: Double
    let sessionsMeasured: Int
    let distribution: [ParityBucket]
}

private struct ParityLongest: Codable, Equatable {
    let id: UUID
    let durationSeconds: Double
    let wordCount: Int
}

private struct ParityUsage: Codable, Equatable {
    let sessions: Int
    let sessionsWithErrors: Int
    let recordingSeconds: Double
    let averageSessionSeconds: Double
    let words: Int
}

private struct ParityExpected: Codable, Equatable {
    /// Each session's words, so a tokenizer difference is reported where it happens.
    let tokens: [[String]]
    let sessionsAnalyzed: Int
    let totalWords: Int
    let totalFillers: Int
    let fillerRatePer1kWords: Double
    let topFillers: [ParityTerm]
    let topBigrams: [ParityTerm]
    let topTrigrams: [ParityTerm]
    let fillerTrend: [ParityWeek]
    let pace: ParityPace
    let longestSession: ParityLongest?
    let usage: ParityUsage
}

final class SpeechInsightsParityTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/speech-insights/parity.json")
    }

    func testSpeakCoreProducesTheSharedFixtureNumbers() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var fixture = try decoder.decode(ParityFixture.self, from: Data(contentsOf: fixtureURL))
        let computed = expected(for: fixture)
        if ProcessInfo.processInfo.environment["UPDATE_SPEECH_INSIGHTS_PARITY"] == "1" {
            fixture.expected = computed
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(fixture)
            data.append(0x0A)
            try data.write(to: fixtureURL)
        }
        XCTAssertEqual(
            fixture.expected, computed,
            "Tests/Fixtures/speech-insights/parity.json is stale. Regenerate with "
                + "UPDATE_SPEECH_INSIGHTS_PARITY=1 swift test --filter SpeechInsightsParityTests"
        )
    }

    private func expected(for fixture: ParityFixture) -> ParityExpected {
        let records = fixture.sessions.map {
            SpeechSessionRecord(id: $0.id, startedAt: $0.startedAt, text: $0.text, duration: $0.durationSeconds)
        }
        let aggregate = SpeechInsightsEngine.computeAggregate(from: records)
        let summary = SpeechInsightsEngine.summary(for: aggregate)
        let longest = aggregate.sessions.max { lhs, rhs in
            if lhs.duration != rhs.duration { return lhs.duration < rhs.duration }
            return lhs.wordCount < rhs.wordCount
        }
        let terms = { (terms: [SpeechInsightsSummary.TermCount]) in
            terms.map { ParityTerm(term: $0.term, count: $0.count) }
        }
        return ParityExpected(
            tokens: fixture.sessions.map { SpeechTokenizer.tokenize($0.text).surfaceTokens },
            sessionsAnalyzed: summary.sessionsAnalyzed,
            totalWords: aggregate.totalWordCount,
            totalFillers: aggregate.totalFillerCount,
            fillerRatePer1kWords: summary.fillerRatePer1kWords,
            topFillers: terms(summary.topFillers),
            topBigrams: terms(summary.topBigrams),
            topTrigrams: terms(summary.topTrigrams),
            fillerTrend: summary.fillerTrend.map {
                ParityWeek(
                    weekStart: SpeechInsightsAggregate.weekKey(for: $0.weekStart),
                    totalWords: $0.totalWords,
                    fillerCount: $0.fillerCount
                )
            },
            pace: ParityPace(
                averageWPM: summary.pace.averageWPM,
                medianWPM: summary.pace.medianWPM,
                sessionsMeasured: summary.pace.sessionsMeasured,
                distribution: summary.pace.distribution.map { ParityBucket(label: $0.label, count: $0.count) }
            ),
            longestSession: longest.map {
                ParityLongest(id: $0.id, durationSeconds: $0.duration, wordCount: $0.wordCount)
            },
            usage: usage(for: fixture.usageEntries)
        )
    }

    private func usage(for entries: [ParityUsageEntry]) -> ParityUsage {
        let usage = HistoryPresentationStatistics(items: entries.map { entry in
            HistoryPresentationItem(
                id: UUID(),
                createdAt: Date(timeIntervalSince1970: 0),
                rawTranscription: entry.rawText,
                processedTranscription: entry.text,
                modelIdentifiers: [],
                recordingDuration: entry.durationSeconds ?? 0,
                errorCount: entry.failed ? 1 : 0,
                originPlatform: "android"
            )
        })
        return ParityUsage(
            sessions: usage.totalSessions,
            sessionsWithErrors: usage.sessionsWithErrors,
            recordingSeconds: usage.cumulativeRecordingDuration,
            averageSessionSeconds: usage.averageSessionLength,
            words: usage.totalWords
        )
    }
}
