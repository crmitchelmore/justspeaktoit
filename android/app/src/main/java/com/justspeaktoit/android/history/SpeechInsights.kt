package com.justspeaktoit.android.history

import org.json.JSONObject
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.temporal.TemporalAdjusters

/**
 * The speech-insights definitions exported from SpeakCore (`assets/speech_insights.json`, written by
 * `SpeechInsightsAndroidExport`): filler phrases, stopwords, pace ranges and result limits. Android
 * keeps no list of its own, so a change in SpeakCore reaches every platform.
 */
data class SpeechInsightsDefinitions(
    val fillerPhrases: List<String>,
    val stopwords: Set<String>,
    val minimumSessionDurationForWpm: Double,
    val topPhraseLimit: Int,
    val topFillerLimit: Int,
    val fillerTrendWeekLimit: Int,
    val wpmBuckets: List<WpmRange>,
) {
    /** A words-per-minute range; [upper] is `null` for the open-ended top range. */
    data class WpmRange(val label: String, val lower: Double, val upper: Double?) {
        fun contains(wpm: Double): Boolean = wpm >= lower && (upper == null || wpm < upper)
    }

    /** Filler phrases as lowercase token sequences, longest first, as SpeakCore matches them. */
    val fillerTokenSequences: List<List<String>> by lazy {
        fillerPhrases
            .map { phrase -> phrase.lowercase().split(' ').filter { it.isNotEmpty() } }
            .filter { it.isNotEmpty() }
            .sortedByDescending { it.size }
    }

    /** Multi-word fillers may surface in top phrases even though every word is a stopword. */
    val multiWordFillerPhrases: Set<String> by lazy {
        fillerTokenSequences.filter { it.size > 1 }.map { it.joinToString(" ") }.toSet()
    }

    companion object {
        const val ASSET = "speech_insights.json"

        fun parse(json: String): SpeechInsightsDefinitions {
            val root = JSONObject(json)
            val fillers = root.getJSONArray("fillerPhrases")
            val stopwords = root.getJSONArray("stopwords")
            val buckets = root.getJSONArray("wpmBuckets")
            return SpeechInsightsDefinitions(
                fillerPhrases = List(fillers.length()) { fillers.getString(it) },
                stopwords = List(stopwords.length()) { stopwords.getString(it) }.toSet(),
                minimumSessionDurationForWpm = root.getDouble("minimumSessionDurationForWPM"),
                topPhraseLimit = root.getInt("topPhraseLimit"),
                topFillerLimit = root.getInt("topFillerLimit"),
                fillerTrendWeekLimit = root.getInt("fillerTrendWeekLimit"),
                wpmBuckets = List(buckets.length()) { index ->
                    val bucket = buckets.getJSONObject(index)
                    WpmRange(
                        label = bucket.getString("label"),
                        lower = bucket.getDouble("lowerBound"),
                        upper = if (bucket.isNull("upperBound")) null else bucket.getDouble("upperBound"),
                    )
                },
            )
        }
    }
}

/** One History entry as the engine reads it, the same projection SpeakCore's `SpeechSessionRecord` makes. */
data class SpeechSession(val id: String, val startedAtMs: Long, val durationSeconds: Double, val text: String) {
    companion object {
        /**
         * Completed entries with text, analysed on the raw transcript when one was kept (the cleaned
         * text is only a fallback), as the Mac and iPhone dashboards do.
         */
        fun from(entry: HistoryEntry): SpeechSession? {
            if (entry.status != HistoryStatus.Completed) return null
            val text = entry.rawText?.takeIf { it.isNotBlank() } ?: entry.text.takeIf { it.isNotBlank() } ?: return null
            return SpeechSession(entry.id, entry.createdAtMs, entry.durationSeconds ?: 0.0, text)
        }
    }
}

data class TermCount(val term: String, val count: Int)

/** Words and fillers in one ISO week (Monday start, UTC). */
data class FillerTrendPoint(val weekStart: LocalDate, val totalWords: Int, val fillerCount: Int) {
    val ratePer1kWords: Double get() = if (totalWords > 0) fillerCount.toDouble() / totalWords * 1000 else 0.0
}

data class WpmBucket(val label: String, val count: Int)

data class PaceStats(
    val averageWpm: Double,
    val medianWpm: Double,
    val distribution: List<WpmBucket>,
    val sessionsMeasured: Int,
)

data class LongestSession(val id: String, val startedAtMs: Long, val durationSeconds: Double, val wordCount: Int)

/**
 * The surface-word statistics of SpeakCore's `SpeechInsightsSummary`. Lemma-based statistics (top
 * words, vocabulary, trending and word of the month) need Apple's NaturalLanguage lemmatiser and are
 * not computed on Android.
 */
data class SpeechInsightsSummary(
    val sessionsAnalyzed: Int,
    val totalWords: Int,
    val totalFillers: Int,
    val fillerRatePer1kWords: Double,
    val topFillers: List<TermCount>,
    val fillerTrend: List<FillerTrendPoint>,
    val topBigrams: List<TermCount>,
    val topTrigrams: List<TermCount>,
    val pace: PaceStats,
    val longestSession: LongestSession?,
)

/**
 * Splits text into lowercase words the way SpeakCore's NaturalLanguage tokenizer does for dictated
 * prose: letters, digits and underscores form words; an apostrophe joins letters ("o'clock"), a full
 * stop joins letters or digits ("3.5", "x.io") and a comma joins digits ("1,000"); everything else
 * separates. Clitics split off as their own words, as NaturalLanguage does: "don't" is "do" + "n't"
 * and "it's" is "it" + "'s".
 */
object SpeechTokenizer {
    private val clitics = listOf("s", "re", "m", "ll", "ve", "d")

    fun tokenize(text: String): List<String> {
        val words = mutableListOf<String>()
        val current = StringBuilder()
        fun flush() {
            if (current.isNotEmpty()) {
                splitClitics(current.toString(), words)
                current.clear()
            }
        }
        for ((index, char) in text.withIndex()) {
            val previous = text.getOrNull(index - 1)
            val next = text.getOrNull(index + 1)
            val joins = when {
                isWordChar(char) -> true
                previous == null || current.isEmpty() -> false
                char == '.' && keepsFinalStop(current, text, index) -> true
                next == null -> false
                isApostrophe(char) -> previous.isLetterOrDigit() && next.isLetter()
                char == '.' -> previous.isLetterOrDigit() && next.isLetterOrDigit()
                char == ',' -> previous.isDigit() && next.isDigit()
                else -> false
            }
            if (joins) current.append(char) else flush()
        }
        flush()
        return words.map { it.lowercase() }.filter { word -> word.any(Char::isLetterOrDigit) }
    }

    /**
     * NaturalLanguage keeps the full stop after an abbreviation unless it ends the text: a dotted
     * word ("a.m.", "e.g.") or a title ("Dr."). It decides some other words ("4b.", "ok.") from
     * context; those differ only in a phrase's text, never in a count.
     */
    private fun keepsFinalStop(word: CharSequence, text: String, index: Int): Boolean {
        val next = text.getOrNull(index + 1)
        if (next != null && !next.isWhitespace()) return false
        if (text.substring(index + 1).isBlank()) return false
        val lower = word.toString().lowercase()
        return '.' in lower || lower in titles
    }

    private val titles = setOf("mr", "mrs", "ms", "dr", "sr", "vs", "prof")

    private fun isWordChar(char: Char): Boolean =
        char.isLetterOrDigit() || char == '_' || Character.getType(char) == Character.NON_SPACING_MARK.toInt()

    private fun isApostrophe(char: Char): Boolean = char == '\'' || char == '\u2019'

    private fun splitClitics(word: String, into: MutableList<String>) {
        val lower = word.lowercase()
        if (word.length > 3 && (lower.endsWith("n't") || lower.endsWith("n\u2019t"))) {
            splitClitics(word.dropLast(3), into)
            into.add(word.takeLast(3))
            return
        }
        for (clitic in clitics) {
            val suffixLength = clitic.length + 1
            if (word.length > suffixLength && lower.endsWith(clitic) && isApostrophe(word[word.length - suffixLength])) {
                splitClitics(word.dropLast(suffixLength), into)
                into.add(word.takeLast(suffixLength))
                return
            }
        }
        into.add(word)
    }

    /** Greedy, non-overlapping, longest phrase first: "sort of" never also counts "of". */
    fun countFillers(tokens: List<String>, phrases: List<List<String>>): Map<String, Int> {
        val ordered = phrases.filter { it.isNotEmpty() }.sortedByDescending { it.size }
        val counts = mutableMapOf<String, Int>()
        var index = 0
        while (index < tokens.size) {
            val match = ordered.firstOrNull { phrase ->
                phrase.size <= tokens.size - index && phrase.indices.all { tokens[index + it] == phrase[it] }
            }
            if (match == null) {
                index += 1
            } else {
                val key = match.joinToString(" ")
                counts[key] = (counts[key] ?: 0) + 1
                index += match.size
            }
        }
        return counts
    }

    fun ngramCounts(tokens: List<String>, size: Int): Map<String, Int> {
        if (size <= 0 || tokens.size < size) return emptyMap()
        val counts = mutableMapOf<String, Int>()
        for (start in 0..tokens.size - size) {
            val gram = tokens.subList(start, start + size).joinToString(" ")
            counts[gram] = (counts[gram] ?: 0) + 1
        }
        return counts
    }
}

/** Mirrors SpeakCore's `SpeechInsightsEngine` aggregate and summary for the surface-word statistics. */
object SpeechInsightsEngine {
    fun summarize(sessions: List<SpeechSession>, definitions: SpeechInsightsDefinitions): SpeechInsightsSummary {
        val unique = sessions.distinctBy { it.id }
        val fillerCounts = mutableMapOf<String, Int>()
        val bigrams = mutableMapOf<String, Int>()
        val trigrams = mutableMapOf<String, Int>()
        val stats = unique.map { session ->
            val tokens = SpeechTokenizer.tokenize(session.text)
            val fillers = SpeechTokenizer.countFillers(tokens, definitions.fillerTokenSequences)
            fillers.forEach { (phrase, count) -> fillerCounts.merge(phrase, count, Int::plus) }
            SpeechTokenizer.ngramCounts(tokens, 2).forEach { (gram, count) -> bigrams.merge(gram, count, Int::plus) }
            SpeechTokenizer.ngramCounts(tokens, 3).forEach { (gram, count) -> trigrams.merge(gram, count, Int::plus) }
            SessionStat(session, maxOf(0.0, session.durationSeconds), tokens.size, fillers.values.sum())
        }.sortedWith(compareBy<SessionStat> { it.session.startedAtMs }.thenBy { it.session.id.uppercase() })

        val totalWords = stats.sumOf { it.wordCount }
        val totalFillers = stats.sumOf { it.fillerCount }
        return SpeechInsightsSummary(
            sessionsAnalyzed = stats.size,
            totalWords = totalWords,
            totalFillers = totalFillers,
            fillerRatePer1kWords = if (totalWords > 0) totalFillers.toDouble() / totalWords * 1000 else 0.0,
            topFillers = topTerms(fillerCounts, definitions.topFillerLimit),
            fillerTrend = fillerTrend(stats, definitions.fillerTrendWeekLimit),
            topBigrams = topPhrases(bigrams, definitions),
            topTrigrams = topPhrases(trigrams, definitions),
            pace = pace(stats, definitions),
            longestSession = longest(stats),
        )
    }

    /** Monday of the ISO week (UTC) containing [epochMs]. */
    fun weekStart(epochMs: Long): LocalDate =
        Instant.ofEpochMilli(epochMs).atZone(ZoneOffset.UTC).toLocalDate()
            .with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))

    private class SessionStat(val session: SpeechSession, val duration: Double, val wordCount: Int, val fillerCount: Int) {
        val wordsPerMinute: Double? get() = if (duration > 0 && wordCount > 0) wordCount / (duration / 60) else null
    }

    private fun topTerms(counts: Map<String, Int>, limit: Int): List<TermCount> =
        counts.entries
            .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .take(maxOf(0, limit))
            .map { TermCount(it.key, it.value) }

    private fun topPhrases(counts: Map<String, Int>, definitions: SpeechInsightsDefinitions): List<TermCount> {
        val kept = counts.filterKeys { gram ->
            gram in definitions.multiWordFillerPhrases || !gram.split(' ').all { it in definitions.stopwords }
        }
        return topTerms(kept, definitions.topPhraseLimit)
    }

    private fun fillerTrend(stats: List<SessionStat>, limit: Int): List<FillerTrendPoint> =
        stats.groupBy { weekStart(it.session.startedAtMs) }
            .map { (week, sessions) -> FillerTrendPoint(week, sessions.sumOf { it.wordCount }, sessions.sumOf { it.fillerCount }) }
            .sortedBy { it.weekStart }
            .takeLast(maxOf(0, limit))

    private fun pace(stats: List<SessionStat>, definitions: SpeechInsightsDefinitions): PaceStats {
        val values = stats.filter { it.duration >= definitions.minimumSessionDurationForWpm }
            .mapNotNull { it.wordsPerMinute }
            .sorted()
        if (values.isEmpty()) return PaceStats(0.0, 0.0, emptyList(), 0)
        val middle = values.size / 2
        val median = if (values.size % 2 == 0) (values[middle - 1] + values[middle]) / 2 else values[middle]
        return PaceStats(
            averageWpm = values.sum() / values.size,
            medianWpm = median,
            distribution = definitions.wpmBuckets.map { range -> WpmBucket(range.label, values.count(range::contains)) },
            sessionsMeasured = values.size,
        )
    }

    /** Longest by duration, then words; the earliest session wins a tie, as in SpeakCore. */
    private fun longest(stats: List<SessionStat>): LongestSession? {
        var best: SessionStat? = null
        for (stat in stats) {
            val current = best
            if (current == null || current.duration < stat.duration ||
                (current.duration == stat.duration && current.wordCount < stat.wordCount)
            ) {
                best = stat
            }
        }
        return best?.let { LongestSession(it.session.id, it.session.startedAtMs, it.duration, it.wordCount) }
    }
}
