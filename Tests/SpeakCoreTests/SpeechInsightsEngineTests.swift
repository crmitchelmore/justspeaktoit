import XCTest

@testable import SpeakCore

// swiftlint:disable file_length type_body_length
final class SpeechInsightsEngineTests: XCTestCase {
    // Wednesday 2026-08-05 noon UTC; canonical week starts Monday 2026-08-03.
    private var now: Date { date(2026, 8, 5) }

    // MARK: - Helpers

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        guard let value = SpeechInsightsAggregate.canonicalCalendar.date(from: components) else {
            XCTFail("invalid test date \(year)-\(month)-\(day)")
            return Date(timeIntervalSince1970: 0)
        }
        return value
    }

    private func record(
        _ text: String,
        on startedAt: Date,
        duration: TimeInterval = 60,
        id: UUID = UUID()
    ) -> SpeechSessionRecord {
        SpeechSessionRecord(id: id, startedAt: startedAt, text: text, duration: duration)
    }

    private func words(_ word: String, count: Int) -> String {
        Array(repeating: word, count: count).joined(separator: " ")
    }

    // MARK: - Canonical bucketing

    func testWeekKey_startsOnMonday() {
        XCTAssertEqual(SpeechInsightsAggregate.weekKey(for: date(2026, 8, 5)), "2026-08-03")
        XCTAssertEqual(SpeechInsightsAggregate.weekKey(for: date(2026, 8, 3)), "2026-08-03")
        XCTAssertEqual(SpeechInsightsAggregate.weekKey(for: date(2026, 8, 9)), "2026-08-03")
        // ISO week straddling a year boundary: 2026-01-01 is a Thursday.
        XCTAssertEqual(SpeechInsightsAggregate.weekKey(for: date(2026, 1, 1)), "2025-12-29")
    }

    func testMonthKey_format() {
        XCTAssertEqual(SpeechInsightsAggregate.monthKey(for: date(2026, 8, 5)), "2026-08")
        XCTAssertEqual(SpeechInsightsAggregate.monthKey(for: date(2026, 1, 31)), "2026-01")
    }

    func testWeekKey_roundTripsThroughDate() {
        let key = SpeechInsightsAggregate.weekKey(for: now)
        let parsed = SpeechInsightsAggregate.date(fromWeekKey: key)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed.map(SpeechInsightsAggregate.weekKey(for:)), key)
    }

    // MARK: - Aggregation basics

    func testEmptyAggregate() {
        let aggregate = SpeechInsightsAggregate()
        XCTAssertTrue(aggregate.isEmpty)

        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now)
        XCTAssertEqual(summary.sessionsAnalyzed, 0)
        XCTAssertTrue(summary.topWords.isEmpty)
        XCTAssertEqual(summary.fillerRatePer1kWords, 0)
        XCTAssertEqual(summary.pace.sessionsMeasured, 0)
        XCTAssertEqual(summary.vocabulary.richness, 0)
        XCTAssertNil(summary.funStats.wordOfTheMonth)
        XCTAssertNil(summary.funStats.longestSessionDate)
    }

    func testTotalWordCount_includesFillersAndStopwords() {
        let aggregate = SpeechInsightsEngine.computeAggregate(
            from: [record("um the alpha", on: now)]
        )
        XCTAssertEqual(aggregate.totalWordCount, 3)
        XCTAssertEqual(Array(aggregate.wordCounts.keys), ["alpha"])
    }

    func testStopwordsAndFillers_excludedFromContentWords() {
        let aggregate = SpeechInsightsEngine.computeAggregate(
            from: [record("um basically the meeting was about the roadmap you know", on: now)]
        )
        XCTAssertNil(aggregate.wordCounts["um"])
        XCTAssertNil(aggregate.wordCounts["basically"])
        XCTAssertNil(aggregate.wordCounts["the"])
        XCTAssertNil(aggregate.wordCounts["you"])
        XCTAssertNotNil(aggregate.wordCounts["meeting"])
        XCTAssertNotNil(aggregate.wordCounts["roadmap"])
    }

    func testLemmatization_foldsInflectionsIntoOneCount() {
        let aggregate = SpeechInsightsEngine.computeAggregate(
            from: [record("The cats and the cat were sleeping.", on: now)]
        )
        XCTAssertEqual(aggregate.wordCounts["cat"], 2)
        XCTAssertNil(aggregate.wordCounts["cats"])
    }

    func testDigitOnlyAndSingleCharacterTokens_excludedFromContentWords() {
        let aggregate = SpeechInsightsEngine.computeAggregate(
            from: [record("route 66 to zone q alpha", on: now)]
        )
        XCTAssertNil(aggregate.wordCounts["66"])
        XCTAssertNil(aggregate.wordCounts["q"])
        XCTAssertNotNil(aggregate.wordCounts["route"])
        // But they still count as spoken words.
        XCTAssertEqual(aggregate.totalWordCount, 6)
    }

    func testTopWords_deterministicOrdering() {
        let aggregate = SpeechInsightsEngine.computeAggregate(
            from: [record("beta beta alpha alpha zebra", on: now)]
        )
        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now)
        XCTAssertEqual(summary.topWords.map(\.term), ["alpha", "beta", "zebra"])
        XCTAssertEqual(summary.topWords.map(\.count), [2, 2, 1])
    }

    func testTopWords_respectsLimit() {
        let config = SpeechInsightsConfiguration(topWordLimit: 2)
        let aggregate = SpeechInsightsEngine.computeAggregate(
            from: [record("alpha alpha alpha beta beta zebra", on: now)],
            configuration: config
        )
        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now, configuration: config)
        XCTAssertEqual(summary.topWords.map(\.term), ["alpha", "beta"])
    }

    // MARK: - Fillers

    func testFillerRatePer1kWords() {
        // 1 filler in 10 spoken words -> 100 per 1k.
        let text = "um alpha beta gamma delta epsilon zeta eta theta iota"
        let aggregate = SpeechInsightsEngine.computeAggregate(from: [record(text, on: now)])
        XCTAssertEqual(aggregate.totalWordCount, 10)
        XCTAssertEqual(aggregate.totalFillerCount, 1)

        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now)
        XCTAssertEqual(summary.fillerRatePer1kWords, 100, accuracy: 0.0001)
    }

    func testFillerCounts_trackedPerPhrase() {
        let aggregate = SpeechInsightsEngine.computeAggregate(
            from: [record("um it was sort of fine um you know sort of", on: now)]
        )
        XCTAssertEqual(aggregate.fillerCounts["um"], 2)
        XCTAssertEqual(aggregate.fillerCounts["sort of"], 2)
        XCTAssertEqual(aggregate.fillerCounts["you know"], 1)
        XCTAssertEqual(aggregate.totalFillerCount, 5)
    }

    func testFillerList_isExtensible() {
        let config = SpeechInsightsConfiguration(fillerPhrases: ["frankly", "to be fair"])
        let aggregate = SpeechInsightsEngine.computeAggregate(
            from: [record("frankly it went well to be fair", on: now)],
            configuration: config
        )
        XCTAssertEqual(aggregate.fillerCounts["frankly"], 1)
        XCTAssertEqual(aggregate.fillerCounts["to be fair"], 1)
        XCTAssertNil(aggregate.fillerCounts["um"])
    }

    func testFillerTrend_weeklyRates() {
        let weekOne = date(2026, 7, 20)
        let weekTwo = date(2026, 7, 27)
        let records = [
            record("um alpha beta gamma delta epsilon zeta eta theta iota", on: weekOne),
            record("um um alpha beta gamma delta epsilon zeta eta theta", on: weekTwo)
        ]
        let summary = SpeechInsightsEngine.summary(
            for: SpeechInsightsEngine.computeAggregate(from: records),
            now: now
        )
        XCTAssertEqual(summary.fillerTrend.count, 2)
        XCTAssertEqual(summary.fillerTrend[0].weekStart, date(2026, 7, 20, hour: 0))
        XCTAssertEqual(summary.fillerTrend[0].ratePer1kWords, 100, accuracy: 0.0001)
        XCTAssertEqual(summary.fillerTrend[1].ratePer1kWords, 200, accuracy: 0.0001)
    }

    func testFillerTrend_respectsWeekLimit() {
        let config = SpeechInsightsConfiguration(fillerTrendWeekLimit: 2)
        let records = (0..<4).map { offset in
            record("alpha beta", on: date(2026, 7, 6 + offset * 7))
        }
        let summary = SpeechInsightsEngine.summary(
            for: SpeechInsightsEngine.computeAggregate(from: records, configuration: config),
            now: now,
            configuration: config
        )
        XCTAssertEqual(summary.fillerTrend.count, 2)
        XCTAssertEqual(summary.fillerTrend.last?.weekStart, date(2026, 7, 27, hour: 0))
    }

    // MARK: - Phrases

    func testTopPhrases_dropAllStopwordGramsButKeepFillerPhrases() {
        let aggregate = SpeechInsightsEngine.computeAggregate(
            from: [record("you know the plan you know the plan", on: now)]
        )
        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now)
        let bigrams = summary.topBigrams.map(\.term)
        XCTAssertTrue(bigrams.contains("you know"), "filler phrases stay visible")
        XCTAssertTrue(bigrams.contains("the plan"))
        XCTAssertFalse(bigrams.contains("know the"), "pure stopword glue is filtered")
    }

    func testTopPhrases_countRepeatedBigramsAndTrigrams() {
        let aggregate = SpeechInsightsEngine.computeAggregate(
            from: [record("launch the rocket launch the rocket", on: now)]
        )
        XCTAssertEqual(aggregate.bigramCounts["launch the"], 2)
        XCTAssertEqual(aggregate.bigramCounts["the rocket"], 2)
        XCTAssertEqual(aggregate.trigramCounts["launch the rocket"], 2)
        XCTAssertEqual(aggregate.trigramCounts["the rocket launch"], 1)
    }

    func testNgrams_doNotCrossSessionBoundaries() {
        let aggregate = SpeechInsightsEngine.computeAggregate(from: [
            record("alpha beta", on: now),
            record("gamma delta", on: now.addingTimeInterval(60))
        ])
        XCTAssertNil(aggregate.bigramCounts["beta gamma"])
        XCTAssertEqual(aggregate.bigramCounts["alpha beta"], 1)
        XCTAssertEqual(aggregate.bigramCounts["gamma delta"], 1)
    }

    // MARK: - Pace

    func testWPM_perSession() {
        let aggregate = SpeechInsightsEngine.computeAggregate(
            from: [record(words("alpha", count: 120), on: now, duration: 60)]
        )
        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now)
        XCTAssertEqual(summary.pace.sessionsMeasured, 1)
        XCTAssertEqual(summary.pace.averageWPM, 120, accuracy: 0.0001)
        XCTAssertEqual(summary.pace.medianWPM, 120, accuracy: 0.0001)
    }

    func testWPM_excludesTooShortSessions() {
        let aggregate = SpeechInsightsEngine.computeAggregate(from: [
            record(words("alpha", count: 120), on: now, duration: 60),
            record("alpha beta", on: now.addingTimeInterval(60), duration: 2),
            record("alpha beta", on: now.addingTimeInterval(120), duration: 0)
        ])
        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now)
        XCTAssertEqual(summary.pace.sessionsMeasured, 1)
    }

    func testWPM_medianOfEvenCount() {
        let aggregate = SpeechInsightsEngine.computeAggregate(from: [
            record(words("alpha", count: 100), on: now, duration: 60),
            record(words("alpha", count: 200), on: now.addingTimeInterval(60), duration: 60)
        ])
        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now)
        XCTAssertEqual(summary.pace.medianWPM, 150, accuracy: 0.0001)
        XCTAssertEqual(summary.pace.averageWPM, 150, accuracy: 0.0001)
    }

    func testWPM_distributionBuckets() {
        let aggregate = SpeechInsightsEngine.computeAggregate(from: [
            record(words("alpha", count: 50), on: now, duration: 60), // 50 wpm
            record(words("alpha", count: 100), on: now.addingTimeInterval(60), duration: 60), // 100
            record(words("alpha", count: 130), on: now.addingTimeInterval(120), duration: 60), // 130
            record(words("alpha", count: 250), on: now.addingTimeInterval(180), duration: 60) // 250
        ])
        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now)
        let counts = Dictionary(
            uniqueKeysWithValues: summary.pace.distribution.map { ($0.label, $0.count) }
        )
        XCTAssertEqual(counts["<60"], 1)
        XCTAssertEqual(counts["90–119"], 1)
        XCTAssertEqual(counts["120–149"], 1)
        XCTAssertEqual(counts["180+"], 1)
        XCTAssertEqual(counts["60–89"], 0)
        XCTAssertEqual(summary.pace.distribution.map(\.count).reduce(0, +), 4)
    }

    // MARK: - Vocabulary

    func testVocabulary_uniqueWordsAndRichness() {
        let aggregate = SpeechInsightsEngine.computeAggregate(
            from: [record("alpha alpha beta", on: now)]
        )
        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now)
        XCTAssertEqual(summary.vocabulary.uniqueWords, 2)
        XCTAssertEqual(summary.vocabulary.totalContentWords, 3)
        XCTAssertEqual(summary.vocabulary.richness, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testVocabulary_newWordsThisWeek() {
        let records = [
            record("alpha alpha", on: date(2026, 7, 20)),
            record("alpha beta beta", on: date(2026, 8, 4))
        ]
        let summary = SpeechInsightsEngine.summary(
            for: SpeechInsightsEngine.computeAggregate(from: records),
            now: now
        )
        XCTAssertEqual(summary.vocabulary.newWordsThisWeek.map(\.term), ["beta"])
        XCTAssertEqual(summary.vocabulary.newWordsThisWeek.first?.count, 2)
    }

    func testVocabulary_firstSeenSurvivesOutOfOrderProcessing() {
        // Process the newer session first; "alpha" must still count as first
        // seen in July, so it is not "new this week".
        var aggregate = SpeechInsightsAggregate()
        SpeechInsightsEngine.update(&aggregate, adding: [record("alpha", on: date(2026, 8, 4))])
        SpeechInsightsEngine.update(&aggregate, adding: [record("alpha", on: date(2026, 7, 10))])
        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now)
        XCTAssertTrue(summary.vocabulary.newWordsThisWeek.isEmpty)
    }

    // MARK: - Trending

    func testTrendingTerms_weekOverWeek() {
        let records = [
            record(words("rocket", count: 1), on: date(2026, 7, 28)),
            record(words("rocket", count: 4) + " " + words("engine", count: 2), on: date(2026, 8, 4))
        ]
        let summary = SpeechInsightsEngine.summary(
            for: SpeechInsightsEngine.computeAggregate(from: records),
            now: now
        )
        XCTAssertEqual(summary.trendingTerms.map(\.term), ["rocket"])
        XCTAssertEqual(summary.trendingTerms.first?.currentWeekCount, 4)
        XCTAssertEqual(summary.trendingTerms.first?.previousWeekCount, 1)
        XCTAssertEqual(summary.trendingTerms.first?.delta, 3)
    }

    func testTrendingTerms_requireMinimumCurrentCount() {
        // "engine" appears twice this week (< default minimum of 3).
        let records = [record(words("engine", count: 2), on: date(2026, 8, 4))]
        let summary = SpeechInsightsEngine.summary(
            for: SpeechInsightsEngine.computeAggregate(from: records),
            now: now
        )
        XCTAssertTrue(summary.trendingTerms.isEmpty)
    }

    func testTrendingTerms_excludeDecliningTerms() {
        let records = [
            record(words("rocket", count: 5), on: date(2026, 7, 28)),
            record(words("rocket", count: 3), on: date(2026, 8, 4))
        ]
        let summary = SpeechInsightsEngine.summary(
            for: SpeechInsightsEngine.computeAggregate(from: records),
            now: now
        )
        XCTAssertTrue(summary.trendingTerms.isEmpty)
    }

    // MARK: - Fun stats

    func testFunStats_totalWordsAndLongestSession() {
        let longestDate = date(2026, 7, 1)
        let aggregate = SpeechInsightsEngine.computeAggregate(from: [
            record("alpha beta gamma", on: now, duration: 30),
            record("delta epsilon", on: longestDate, duration: 300)
        ])
        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now)
        XCTAssertEqual(summary.funStats.totalWordsAllTime, 5)
        XCTAssertEqual(summary.funStats.longestSessionDuration, 300)
        XCTAssertEqual(summary.funStats.longestSessionWordCount, 2)
        XCTAssertEqual(summary.funStats.longestSessionDate, longestDate)
    }

    func testFunStats_wordOfTheMonth() {
        let aggregate = SpeechInsightsEngine.computeAggregate(from: [
            record(words("julyword", count: 9), on: date(2026, 7, 10)),
            record(words("augustword", count: 3) + " other", on: date(2026, 8, 2))
        ])
        let summary = SpeechInsightsEngine.summary(for: aggregate, now: now)
        XCTAssertEqual(summary.funStats.wordOfTheMonth, "augustword")
    }

    func testFunStats_wordOfTheMonthFallsBackToLatestMonthWithData() {
        let aggregate = SpeechInsightsEngine.computeAggregate(from: [
            record(words("julyword", count: 3), on: date(2026, 7, 10))
        ])
        let summary = SpeechInsightsEngine.summary(for: aggregate, now: date(2026, 9, 10))
        XCTAssertEqual(summary.funStats.wordOfTheMonth, "julyword")
    }

    // MARK: - Incremental vs full equivalence

    private func sampleRecords() -> [SpeechSessionRecord] {
        [
            record("um so basically the quarterly roadmap is sort of ready", on: date(2026, 6, 3), duration: 42),
            record("you know the rocket launch went really well", on: date(2026, 7, 1), duration: 95),
            record(words("rocket", count: 4) + " staging test complete", on: date(2026, 8, 4), duration: 61),
            record("The cats and the cat were sleeping.", on: date(2026, 5, 20), duration: 12),
            record("um um uh checking the microphone", on: date(2026, 8, 3), duration: 8),
            record("", on: date(2026, 8, 1), duration: 30)
        ]
    }

    func testIncrementalUpdates_matchFullRecompute() {
        let records = sampleRecords()
        let full = SpeechInsightsEngine.computeAggregate(from: records)

        // Apply in three batches, deliberately out of chronological order.
        var incremental = SpeechInsightsAggregate()
        SpeechInsightsEngine.update(&incremental, adding: Array(records[4...5]))
        SpeechInsightsEngine.update(&incremental, adding: Array(records[0...1]))
        SpeechInsightsEngine.update(&incremental, adding: Array(records[2...3]))

        XCTAssertEqual(incremental, full)
        XCTAssertEqual(
            SpeechInsightsEngine.summary(for: incremental, now: now),
            SpeechInsightsEngine.summary(for: full, now: now)
        )
    }

    func testUpdate_isIdempotentForAlreadyProcessedSessions() {
        let records = sampleRecords()
        var aggregate = SpeechInsightsEngine.computeAggregate(from: records)
        let before = aggregate
        SpeechInsightsEngine.update(&aggregate, adding: records)
        XCTAssertEqual(aggregate, before)
    }

    func testSessions_keptInCanonicalOrder() {
        let records = sampleRecords()
        let aggregate = SpeechInsightsEngine.computeAggregate(from: records.reversed())
        let dates = aggregate.sessions.map(\.startedAt)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(aggregate.sessions.count, records.count)
    }

    // MARK: - Reconcile

    func testReconcile_foldsInOnlyNewSessions() {
        let records = sampleRecords()
        let aggregate = SpeechInsightsEngine.computeAggregate(from: Array(records[0..<4]))
        let reconciled = SpeechInsightsEngine.reconcile(aggregate, with: records)
        XCTAssertEqual(reconciled, SpeechInsightsEngine.computeAggregate(from: records))
    }

    func testReconcile_withNoChangesReturnsEqualAggregate() {
        let records = sampleRecords()
        let aggregate = SpeechInsightsEngine.computeAggregate(from: records)
        XCTAssertEqual(SpeechInsightsEngine.reconcile(aggregate, with: records), aggregate)
    }

    func testReconcile_recomputesAfterDeletion() {
        // Retention policies and manual deletes must remove the deleted
        // transcript's contribution entirely.
        let records = sampleRecords()
        let aggregate = SpeechInsightsEngine.computeAggregate(from: records)
        let remaining = Array(records.dropFirst())
        let reconciled = SpeechInsightsEngine.reconcile(aggregate, with: remaining)
        XCTAssertEqual(reconciled, SpeechInsightsEngine.computeAggregate(from: remaining))
        XCTAssertFalse(reconciled.processedSessionIDs.contains(records[0].id))
    }

    func testReconcile_recomputesAfterClearAll() {
        let aggregate = SpeechInsightsEngine.computeAggregate(from: sampleRecords())
        let reconciled = SpeechInsightsEngine.reconcile(aggregate, with: [])
        XCTAssertTrue(reconciled.isEmpty)
    }

    func testReconcile_recomputesOnSchemaMismatch() {
        let records = sampleRecords()
        var stale = SpeechInsightsEngine.computeAggregate(from: Array(records[0..<2]))
        stale.schemaVersion = 0
        let reconciled = SpeechInsightsEngine.reconcile(stale, with: records)
        XCTAssertEqual(reconciled, SpeechInsightsEngine.computeAggregate(from: records))
    }

    // MARK: - Persistence

    func testAggregate_codableRoundTrip() throws {
        let aggregate = SpeechInsightsEngine.computeAggregate(from: sampleRecords())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            SpeechInsightsAggregate.self,
            from: encoder.encode(aggregate)
        )
        XCTAssertEqual(decoded, aggregate)
        XCTAssertEqual(
            SpeechInsightsEngine.summary(for: decoded, now: now),
            SpeechInsightsEngine.summary(for: aggregate, now: now)
        )
    }
}
// swiftlint:enable file_length type_body_length
