package com.justspeaktoit.android.settings

import com.justspeaktoit.android.cloud.CloudCatalog
import org.json.JSONObject

/**
 * One searchable Settings destination. Entries come from the shared Swift catalogue
 * (`Sources/SpeakCore/SettingsSearch`), exported to `assets/settings_search.json`.
 */
data class SettingsSearchEntry(
    val id: String,
    val title: String,
    val sectionTitle: String,
    val summary: String,
    val keywords: List<String>,
    val settingKeys: List<String>,
) {
    /** Stable test tag shared with the Apple and desktop apps. */
    val resultTag: String get() = "settingsSearchResult.$id"
}

data class SettingsSearchResult(val entry: SettingsSearchEntry, val score: Int, val matchedKeyword: String?)

/**
 * Ranked search with the same rules as `SettingsSearchIndex` in SpeakCore: title beats
 * keyword beats page or summary; synonyms, inflections and small typos still match; and
 * every meaningful query word must match.
 */
class SettingsSearchIndex(val entries: List<SettingsSearchEntry>, synonymGroups: List<List<String>>) {
    private class Phrase(val original: String, val normalized: String, val words: List<String>)

    private class Document(val entry: SettingsSearchEntry) {
        val title = normalize(entry.title)
        val titleWords = words(entry.title)
        val keywords = entry.keywords.map { Phrase(it, normalize(it), words(it)) }
        val sectionWords = words(entry.sectionTitle)
        val summaryWords = words(entry.summary)
        val settingKeys = entry.settingKeys.map { it.lowercase() }
    }

    private class Match(val score: Int, val keyword: String?, val hitTitle: Boolean)

    private val documents = entries.map(::Document)
    private val byId = documents.associateBy { it.entry.id }
    private val synonyms: Map<String, List<String>> = buildMap<String, MutableList<String>> {
        for (group in synonymGroups) for (word in group) getOrPut(word) { mutableListOf() } += group - word
    }

    fun entry(id: String): SettingsSearchEntry? = byId[id]?.entry

    fun search(query: String, limit: Int = 25): List<SettingsSearchResult> {
        val normalizedQuery = normalize(query)
        val all = normalizedQuery.split(' ').filter { it.isNotEmpty() }
        val meaningful = all.filter { it !in STOP_WORDS }
        val tokens = meaningful.ifEmpty { all }
        if (tokens.isEmpty()) return emptyList()
        return documents.mapNotNull { score(it, normalizedQuery, tokens) }
            .sortedWith(compareByDescending<SettingsSearchResult> { it.score }.thenBy { it.entry.title })
            .take(limit)
    }

    /** Titles and keywords that extend what has been typed, for typeahead. */
    fun completions(query: String, limit: Int = 5): List<String> {
        val normalizedQuery = normalize(query)
        if (normalizedQuery.isEmpty()) return emptyList()
        val seen = mutableSetOf<String>()
        val ranked = mutableListOf<Pair<String, Int>>()
        fun consider(phrase: String, normalized: String, isTitle: Boolean) {
            if (normalized == normalizedQuery || normalized in seen) return
            val rank = when {
                normalized.startsWith(normalizedQuery) -> if (isTitle) 0 else 1
                normalized.contains(" $normalizedQuery") -> if (isTitle) 2 else 3
                else -> return
            }
            seen += normalized
            ranked += phrase to rank * 1_000 + normalized.length
        }
        for (document in documents) {
            consider(document.entry.title, document.title, true)
            for (keyword in document.keywords) consider(keyword.original, keyword.normalized, false)
        }
        return ranked.sortedWith(compareBy({ it.second }, { it.first })).take(limit).map { it.first }
    }

    private fun score(document: Document, query: String, tokens: List<String>): SettingsSearchResult? {
        var total = 0
        var keyword: String? = null
        var titleHits = 0
        for (token in tokens) {
            val match = bestMatch(token, document) ?: return null
            total += match.score
            if (match.hitTitle) titleHits++
            if (keyword == null) keyword = match.keyword
        }
        if (document.title == query) total += 300 else if (document.title.startsWith(query)) total += 150
        val exact = document.keywords.firstOrNull { it.normalized == query }
        if (exact != null) {
            total += 120
            keyword = exact.original
        } else {
            document.keywords.firstOrNull { it.normalized.startsWith(query) }?.let {
                total += 60
                if (keyword == null) keyword = it.original
            }
        }
        return SettingsSearchResult(document.entry, total, if (titleHits == tokens.size) null else keyword)
    }

    private fun bestMatch(token: String, document: Document): Match? {
        var best = directMatch(token, document)
        for (synonym in synonyms[token].orEmpty()) {
            val match = directMatch(synonym, document) ?: continue
            val scaled = Match(match.score * 4 / 5, match.keyword, match.hitTitle)
            if (scaled.score > (best?.score ?: 0)) best = scaled
        }
        return best
    }

    private fun directMatch(token: String, document: Document): Match? {
        var best: Match? = null
        fun offer(score: Int, keyword: String? = null, hitTitle: Boolean = false) {
            if (score > (best?.score ?: 0)) best = Match(score, keyword, hitTitle)
        }
        val allowsInfix = token.length >= 3
        for (word in document.titleWords) {
            when {
                word == token -> offer(100, hitTitle = true)
                word.startsWith(token) -> offer(80, hitTitle = true)
                extends(token, word) -> offer(60, hitTitle = true)
            }
        }
        if (allowsInfix && document.title.contains(token)) offer(40, hitTitle = true)
        for (keyword in document.keywords) {
            for (word in keyword.words) {
                when {
                    word == token -> offer(70, keyword.original)
                    word.startsWith(token) -> offer(55, keyword.original)
                    extends(token, word) -> offer(45, keyword.original)
                }
            }
            if (allowsInfix && keyword.normalized.contains(token)) offer(25, keyword.original)
        }
        if (document.sectionWords.any { it.startsWith(token) }) offer(30)
        if (document.summaryWords.any { it.startsWith(token) }) offer(20)
        if (token.length >= 4 && document.settingKeys.any { it.contains(token) }) offer(15)
        if (best == null && token.length >= 4) {
            val tolerance = if (token.length >= 8) 2 else 1
            val keyword = document.keywords.firstOrNull { phrase -> phrase.words.any { isWithin(tolerance, token, it) } }
            when {
                document.titleWords.any { isWithin(tolerance, token, it) } -> offer(12, hitTitle = true)
                keyword != null -> offer(10, keyword.original)
            }
        }
        return best
    }

    companion object {
        private val STOP_WORDS = setOf(
            "a", "an", "and", "the", "to", "of", "for", "in", "on", "is", "my", "i", "when", "with", "how", "do", "it",
        )

        /** Parses the exported catalogue and adds one entry per cloud model and provider key. */
        fun fromCatalogueJson(json: String): SettingsSearchIndex {
            val root = JSONObject(json)
            val synonymsArray = root.getJSONArray("synonyms")
            val synonyms = (0 until synonymsArray.length()).map { index ->
                val group = synonymsArray.getJSONArray(index)
                (0 until group.length()).map(group::getString)
            }
            val entriesArray = root.getJSONArray("entries")
            val entries = (0 until entriesArray.length()).map { index ->
                val entry = entriesArray.getJSONObject(index)
                SettingsSearchEntry(
                    id = entry.getString("id"),
                    title = entry.getString("title"),
                    sectionTitle = entry.getString("sectionTitle"),
                    summary = entry.getString("summary"),
                    keywords = entry.getJSONArray("keywords").let { array -> (0 until array.length()).map(array::getString) },
                    settingKeys = entry.getJSONArray("settingKeys").let { array -> (0 until array.length()).map(array::getString) },
                )
            }
            return SettingsSearchIndex(entries + runtimeEntries(), synonyms)
        }

        /** Generated from `CloudCatalog`, so a new model or provider is searchable without edits here. */
        fun runtimeEntries(): List<SettingsSearchEntry> =
            CloudCatalog.transcriptionModels.map { model ->
                SettingsSearchEntry(
                    id = "$MODEL_PREFIX${model.catalogId}",
                    title = model.displayName,
                    sectionTitle = "Transcription",
                    summary = "Use ${model.displayName} for cloud dictation.",
                    keywords = listOf(model.provider.displayName, "cloud transcription model", "model picker"),
                    settingKeys = emptyList(),
                )
            } + CloudCatalog.providers.map { provider ->
                SettingsSearchEntry(
                    id = "$KEY_PREFIX${provider.id}",
                    title = "${provider.displayName} API key",
                    sectionTitle = "API Keys",
                    summary = "Add or remove the ${provider.displayName} key.",
                    keywords = listOf(provider.displayName, "api key", "token", "credentials"),
                    settingKeys = emptyList(),
                )
            }

        const val MODEL_PREFIX = "android.model."
        const val KEY_PREFIX = "android.key."

        fun normalize(text: String): String = words(text).joinToString(" ")

        fun words(text: String): List<String> =
            text.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }

        /** Whether `token` is an inflection of `word`, such as "cancelled" for "cancel". */
        private fun extends(token: String, word: String): Boolean =
            word.length >= 4 && token.length - word.length <= 4 && token.startsWith(word)

        /** Whether two words are within `tolerance` edits (Levenshtein distance). */
        fun isWithin(tolerance: Int, lhs: String, rhs: String): Boolean {
            if (kotlin.math.abs(lhs.length - rhs.length) > tolerance) return false
            var previous = IntArray(rhs.length + 1) { it }
            for (row in lhs.indices) {
                val current = IntArray(rhs.length + 1)
                current[0] = row + 1
                var rowMinimum = current[0]
                for (column in rhs.indices) {
                    val substitution = previous[column] + if (lhs[row] == rhs[column]) 0 else 1
                    current[column + 1] = minOf(substitution, previous[column + 1] + 1, current[column] + 1)
                    rowMinimum = minOf(rowMinimum, current[column + 1])
                }
                if (rowMinimum > tolerance) return false
                previous = current
            }
            return previous[rhs.length] <= tolerance
        }
    }
}

/** Most recently opened entry ids, newest first. */
object SettingsSearchRecents {
    fun recording(id: String, recents: List<String>, limit: Int = 6): List<String> =
        (listOf(id) + recents.filter { it != id }).take(limit)
}
