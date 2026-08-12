import Foundation

/// Tunable knobs for the speech-insights pipeline.
///
/// The defaults are deliberately conservative; every list is a plain value so
/// callers (and tests) can extend or replace them without touching the engine.
public struct SpeechInsightsConfiguration: Sendable {
    /// Filler and hedge phrases counted per session. Entries may span multiple
    /// words ("you know", "sort of"); matching is case-insensitive, greedy and
    /// non-overlapping, so "sort of" never double-counts a trailing "of".
    public var fillerPhrases: [String]

    /// Words excluded from the content-word statistics (top words, vocabulary,
    /// trending terms). Matching is applied to both the surface token and its
    /// lemma.
    public var stopwords: Set<String>

    /// Sessions shorter than this are excluded from words-per-minute stats so
    /// one-word test recordings do not distort the distribution.
    public var minimumSessionDurationForWPM: TimeInterval

    /// Minimum times a term must appear in the current week before it can be
    /// reported as trending.
    public var minimumTrendingCount: Int

    /// Result-size limits used when deriving a summary from the aggregate.
    public var topWordLimit: Int
    public var topPhraseLimit: Int
    public var topFillerLimit: Int
    public var newWordLimit: Int
    public var trendingTermLimit: Int
    /// Number of trailing weeks shown in the filler-rate trend.
    public var fillerTrendWeekLimit: Int

    public init(
        fillerPhrases: [String] = SpeechInsightsConfiguration.defaultFillerPhrases,
        stopwords: Set<String> = SpeechInsightsConfiguration.defaultStopwords,
        minimumSessionDurationForWPM: TimeInterval = 10,
        minimumTrendingCount: Int = 3,
        topWordLimit: Int = 20,
        topPhraseLimit: Int = 10,
        topFillerLimit: Int = 6,
        newWordLimit: Int = 15,
        trendingTermLimit: Int = 8,
        fillerTrendWeekLimit: Int = 12
    ) {
        self.fillerPhrases = fillerPhrases
        self.stopwords = stopwords
        self.minimumSessionDurationForWPM = minimumSessionDurationForWPM
        self.minimumTrendingCount = minimumTrendingCount
        self.topWordLimit = topWordLimit
        self.topPhraseLimit = topPhraseLimit
        self.topFillerLimit = topFillerLimit
        self.newWordLimit = newWordLimit
        self.trendingTermLimit = trendingTermLimit
        self.fillerTrendWeekLimit = fillerTrendWeekLimit
    }

    public static let `default` = SpeechInsightsConfiguration()

    /// Filler phrases split into lowercase token sequences, longest first, so
    /// the tokenizer can match multi-word phrases greedily.
    var fillerTokenSequences: [[String]] {
        fillerPhrases
            .map { $0.lowercased().split(separator: " ").map(String.init) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    /// Single-word fillers; excluded from content-word statistics so "um" does
    /// not top the vocabulary charts.
    var singleWordFillers: Set<String> {
        Set(fillerTokenSequences.filter { $0.count == 1 }.map { $0[0] })
    }

    /// Multi-word filler phrases (joined by single spaces) that are allowed to
    /// surface in the top-phrases list even though every token is a stopword.
    var multiWordFillerPhrases: Set<String> {
        Set(fillerTokenSequences.filter { $0.count > 1 }.map { $0.joined(separator: " ") })
    }

    public static let defaultFillerPhrases: [String] = [
        "um", "uh", "uhm", "erm", "hmm", "mmm",
        "like", "basically", "literally",
        "you know", "sort of", "kind of", "i mean"
    ]

    private static func makeDefaultStopwords() -> Set<String> {
        [
            // Articles, conjunctions, prepositions.
            "a", "an", "the", "and", "or", "but", "nor", "so", "yet", "if", "then", "than",
            "because", "while", "of", "to", "in", "on", "at", "by", "for", "with", "about",
            "against", "between", "into", "through", "during", "before", "after", "above",
            "below", "from", "up", "down", "out", "off", "over", "under", "again", "further",
            "as", "until", "since", "per",
            // Pronouns and determiners.
            "i", "me", "my", "myself", "we", "our", "ours", "ourselves", "you", "your",
            "yours", "yourself", "yourselves", "he", "him", "his", "himself", "she", "her",
            "hers", "herself", "it", "its", "itself", "they", "them", "their", "theirs",
            "themselves", "this", "that", "these", "those", "which", "who", "whom", "whose",
            "what", "whatever", "each", "every", "both", "few", "more", "most", "other",
            "some", "such", "any", "all", "no", "not", "only", "own", "same", "another",
            // Verbs (be/have/do/modals) and common contractions.
            "am", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
            "having", "do", "does", "did", "doing", "will", "would", "shall", "should",
            "can", "could", "may", "might", "must", "ought", "let", "lets",
            "i'm", "i've", "i'll", "i'd", "you're", "you've", "you'll", "you'd", "he's",
            "she's", "it's", "we're", "we've", "we'll", "we'd", "they're", "they've",
            "they'll", "they'd", "isn't", "aren't", "wasn't", "weren't", "hasn't",
            "haven't", "hadn't", "doesn't", "don't", "didn't", "won't", "wouldn't",
            "shan't", "shouldn't", "can't", "cannot", "couldn't", "mustn't", "that's",
            "there's", "here's", "what's", "who's", "let's", "gonna", "wanna", "gotta",
            // Adverbs, interjections and other glue.
            "here", "there", "where", "when", "why", "how", "very", "just", "too", "also",
            "quite", "really", "well", "now", "still", "even", "ever", "never", "always",
            "often", "once", "yes", "yeah", "yep", "no", "nope", "okay", "ok", "oh", "hey",
            "hi", "hello", "please", "thanks", "thank", "bye", "etc", "one", "two", "three",
            "get", "got", "go", "going", "went", "come", "came", "make", "made", "put",
            "say", "said", "see", "saw", "know", "knew", "think", "thought", "want",
            "thing", "things", "stuff", "way", "lot", "bit", "mean", "right"
        ]
    }

    public static let defaultStopwords: Set<String> = makeDefaultStopwords()
}
