import Foundation

/// Pure, on-device analytics over raw dictation transcripts.
///
/// The engine has three jobs:
/// 1. Fold sessions into a `SpeechInsightsAggregate` — either from scratch
///    (`computeAggregate`) or incrementally (`update`). Both paths produce
///    identical aggregates for the same set of sessions.
/// 2. Reconcile a persisted aggregate against the current history
///    (`reconcile`): new sessions are folded in incrementally; if any
///    previously processed session has been deleted (manual delete, retention
///    policy, clear-all) the aggregate is rebuilt from what remains.
/// 3. Derive a display-ready `SpeechInsightsSummary` from an aggregate.
///
/// All functions are pure and everything they touch is `Sendable`, so callers
/// are free to run them off the main actor.
public enum SpeechInsightsEngine {
    // MARK: - Aggregation

    /// Builds an aggregate from scratch. Used for first runs, schema upgrades
    /// and as the correctness reference for the incremental path.
    public static func computeAggregate(
        from records: [SpeechSessionRecord],
        configuration: SpeechInsightsConfiguration = .default
    ) -> SpeechInsightsAggregate {
        var aggregate = SpeechInsightsAggregate()
        update(&aggregate, adding: records, configuration: configuration)
        return aggregate
    }

    /// Folds `records` into `aggregate`. Records whose IDs were already
    /// processed are skipped, so the call is idempotent.
    public static func update(
        _ aggregate: inout SpeechInsightsAggregate,
        adding records: [SpeechSessionRecord],
        configuration: SpeechInsightsConfiguration = .default
    ) {
        var addedSessions = false
        for record in records where !aggregate.processedSessionIDs.contains(record.id) {
            fold(record, into: &aggregate, configuration: configuration)
            addedSessions = true
        }
        if addedSessions {
            aggregate.sessions.sort {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    /// Folds a single unseen session into the aggregate.
    private static func fold(
        _ record: SpeechSessionRecord,
        into aggregate: inout SpeechInsightsAggregate,
        configuration: SpeechInsightsConfiguration
    ) {
        aggregate.processedSessionIDs.insert(record.id)
        aggregate.sessionFingerprints[record.id] = record.contentFingerprint

        let tokenized = SpeechTokenizer.tokenize(record.text)
        let surfaces = tokenized.surfaceTokens

        let fillers = SpeechTokenizer.matchFillers(
            in: surfaces,
            phrases: configuration.fillerTokenSequences
        )
        let sessionFillerCount = fillers.counts.values.reduce(0, +)
        for (phrase, count) in fillers.counts {
            aggregate.fillerCounts[phrase, default: 0] += count
        }
        aggregate.totalFillerCount += sessionFillerCount
        aggregate.totalWordCount += surfaces.count

        let contentWords = contentWords(
            in: tokenized,
            excludingIndices: fillers.consumedTokenIndices,
            stopwords: configuration.stopwords,
            singleWordFillers: configuration.singleWordFillers
        )
        let weekKey = SpeechInsightsAggregate.weekKey(for: record.startedAt)
        let monthKey = SpeechInsightsAggregate.monthKey(for: record.startedAt)
        for word in contentWords {
            aggregate.wordCounts[word, default: 0] += 1
            aggregate.weeklyWordCounts[weekKey, default: [:]][word, default: 0] += 1
            aggregate.monthlyWordCounts[monthKey, default: [:]][word, default: 0] += 1
            if let existing = aggregate.firstSeenByWord[word] {
                if record.startedAt < existing {
                    aggregate.firstSeenByWord[word] = record.startedAt
                }
            } else {
                aggregate.firstSeenByWord[word] = record.startedAt
            }
        }

        for (gram, count) in SpeechTokenizer.ngramCounts(of: surfaces, size: 2) {
            aggregate.bigramCounts[gram, default: 0] += count
        }
        for (gram, count) in SpeechTokenizer.ngramCounts(of: surfaces, size: 3) {
            aggregate.trigramCounts[gram, default: 0] += count
        }

        aggregate.sessions.append(
            SpeechInsightsAggregate.SessionStat(
                id: record.id,
                startedAt: record.startedAt,
                duration: max(0, record.duration),
                wordCount: surfaces.count,
                fillerCount: sessionFillerCount
            )
        )
    }

    /// Brings a persisted aggregate in line with the current history.
    ///
    /// - New sessions are folded in incrementally.
    /// - If any processed session no longer exists in `records` (deletion or
    ///   retention), was edited in place (content fingerprint changed under an
    ///   existing UUID — CloudKit merge, local reprocessing), or the schema
    ///   version changed, the aggregate is rebuilt from `records` so obsolete
    ///   contributions stop counting.
    public static func reconcile(
        _ aggregate: SpeechInsightsAggregate,
        with records: [SpeechSessionRecord],
        configuration: SpeechInsightsConfiguration = .default
    ) -> SpeechInsightsAggregate {
        guard aggregate.schemaVersion == SpeechInsightsAggregate.currentSchemaVersion else {
            return computeAggregate(from: records, configuration: configuration)
        }
        let recordsByID = Dictionary(
            records.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for id in aggregate.processedSessionIDs {
            guard let record = recordsByID[id],
                  aggregate.sessionFingerprints[id] == record.contentFingerprint
            else {
                // Deleted or edited in place: rebuild from what remains.
                return computeAggregate(from: records, configuration: configuration)
            }
        }
        let newRecords = records.filter { !aggregate.processedSessionIDs.contains($0.id) }
        guard !newRecords.isEmpty else { return aggregate }
        var updated = aggregate
        update(&updated, adding: newRecords, configuration: configuration)
        return updated
    }

    /// Lemmatized content words for one session: tokens consumed by a matched
    /// filler phrase (single- or multi-word) excluded, filler and stopword
    /// tokens removed (checking both surface and lemma), single characters
    /// and digit-only tokens dropped.
    private static func contentWords(
        in tokenized: SpeechTokenizer.TokenizedText,
        excludingIndices excluded: Set<Int>,
        stopwords: Set<String>,
        singleWordFillers: Set<String>
    ) -> [String] {
        var words: [String] = []
        words.reserveCapacity(tokenized.lemmas.count)
        for (index, (surface, lemma)) in zip(tokenized.surfaceTokens, tokenized.lemmas).enumerated() {
            if excluded.contains(index) { continue }
            if stopwords.contains(surface) || stopwords.contains(lemma) { continue }
            if singleWordFillers.contains(surface) || singleWordFillers.contains(lemma) { continue }
            if lemma.count < 2 { continue }
            if lemma.rangeOfCharacter(from: .letters) == nil { continue }
            words.append(lemma)
        }
        return words
    }
}
