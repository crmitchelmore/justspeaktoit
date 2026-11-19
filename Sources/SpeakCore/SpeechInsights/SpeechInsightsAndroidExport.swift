import Foundation

/// The speech-insights definitions Android's dashboard mirrors, as JSON: the
/// filler phrases, stopwords, words-per-minute ranges and result limits of
/// `SpeechInsightsConfiguration.default`, so Android counts fillers, phrases
/// and pace exactly as the Mac and iOS do without keeping its own lists.
///
/// Android has no on-device lemmatiser, so the lemma-based statistics (top
/// words, vocabulary, trending terms, word of the month) are not exported.
/// `Tests/Fixtures/speech-insights/parity.json` checks that Swift and Kotlin
/// produce the same numbers for the same history.
/// `SpeechInsightsAndroidExportTests` fails when the committed asset is stale;
/// regenerate it with `scripts/update-android-assets`.
public enum SpeechInsightsAndroidExport {
    public static func json(configuration: SpeechInsightsConfiguration = .default) throws -> Data {
        struct Bucket: Encodable {
            let label: String
            let lowerBound: Double
            /// `nil` for the open-ended top range.
            let upperBound: Double?
        }
        struct Document: Encodable {
            let version: Int
            let fillerPhrases: [String]
            let stopwords: [String]
            let minimumSessionDurationForWPM: Double
            let topPhraseLimit: Int
            let topFillerLimit: Int
            let fillerTrendWeekLimit: Int
            let wpmBuckets: [Bucket]
        }
        let document = Document(
            version: 1,
            fillerPhrases: configuration.fillerPhrases,
            stopwords: configuration.stopwords.sorted(),
            minimumSessionDurationForWPM: configuration.minimumSessionDurationForWPM,
            topPhraseLimit: configuration.topPhraseLimit,
            topFillerLimit: configuration.topFillerLimit,
            fillerTrendWeekLimit: configuration.fillerTrendWeekLimit,
            wpmBuckets: SpeechInsightsEngine.wpmBucketBounds.map {
                Bucket(label: $0.label, lowerBound: $0.lower, upperBound: $0.upper.isFinite ? $0.upper : nil)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }
}
