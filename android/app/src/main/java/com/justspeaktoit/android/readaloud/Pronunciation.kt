package com.justspeaktoit.android.readaloud

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.Locale
import java.util.UUID
import java.util.regex.PatternSyntaxException

/**
 * One pronunciation dictionary entry, in SpeakCore's `PronunciationEntry` format (the `pronunciation`
 * records of `DataMigrationVocabularyCatalog`), so a dictionary moves between Android and the other
 * apps unchanged. Read aloud speaks [replacement] wherever [word] appears.
 */
data class PronunciationEntry(
    /** An uppercase UUID, as Swift's `UUID` encodes. */
    val id: String,
    val word: String,
    val pronunciation: String,
    val replacement: String? = null,
    val category: String? = null,
    val isRegex: Boolean = false,
    val caseSensitive: Boolean = false,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put(ID, id)
        put(WORD, word)
        put(PRONUNCIATION, pronunciation)
        // Swift encodes a nil optional by leaving the key out.
        replacement?.let { put(REPLACEMENT, it) }
        category?.let { put(CATEGORY, it) }
        put(IS_REGEX, isRegex)
        put(CASE_SENSITIVE, caseSensitive)
    }

    companion object {
        private const val ID = "id"
        private const val WORD = "word"
        private const val PRONUNCIATION = "pronunciation"
        private const val REPLACEMENT = "replacement"
        private const val CATEGORY = "category"
        private const val IS_REGEX = "isRegex"
        private const val CASE_SENSITIVE = "caseSensitive"
        private val UUID_PATTERN = Regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")

        fun newId(): String = UUID.randomUUID().toString().uppercase(Locale.ROOT)

        /** A stable identity for a shared default, so it is the same entry every time it is seeded. */
        fun defaultId(word: String): String =
            UUID.nameUUIDFromBytes("pronunciation:$word".toByteArray(Charsets.UTF_8)).toString().uppercase(Locale.ROOT)

        /** Decodes exactly what Swift's `Codable` accepts; anything else is null. */
        fun fromJson(json: JSONObject): PronunciationEntry? {
            val id = (json.opt(ID) as? String)?.takeIf(UUID_PATTERN::matches) ?: return null
            val word = json.opt(WORD) as? String ?: return null
            val pronunciation = json.opt(PRONUNCIATION) as? String ?: return null
            val isRegex = json.opt(IS_REGEX) as? Boolean ?: return null
            val caseSensitive = json.opt(CASE_SENSITIVE) as? Boolean ?: return null
            val replacement = optionalString(json, REPLACEMENT) ?: return null
            val category = optionalString(json, CATEGORY) ?: return null
            return PronunciationEntry(
                id = id.uppercase(Locale.ROOT),
                word = word,
                pronunciation = pronunciation,
                replacement = replacement.getOrNull(),
                category = category.getOrNull(),
                isRegex = isRegex,
                caseSensitive = caseSensitive,
            )
        }

        /** A missing or null optional is a success holding null; a value of another type is null. */
        private fun optionalString(json: JSONObject, key: String): Result<String?>? = when {
            !json.has(key) || json.isNull(key) -> Result.success(null)
            else -> (json.opt(key) as? String)?.let { Result.success(it) }
        }

        fun encodeList(entries: List<PronunciationEntry>): String =
            JSONArray().apply { entries.forEach { put(it.toJson()) } }.toString()

        /** Null when the stored text is not a dictionary, so a damaged one is never silently replaced. */
        fun decodeList(text: String): List<PronunciationEntry>? = try {
            val array = JSONArray(text)
            (0 until array.length()).map { index ->
                val item = array.optJSONObject(index) ?: return null
                fromJson(item) ?: return null
            }
        } catch (_: JSONException) {
            null
        }
    }
}

/** Why entries cannot be saved, as SpeakCore's `PronunciationDictionary.validate` decides. */
enum class PronunciationProblem { Empty, Duplicate, InvalidPattern }

object PronunciationDictionary {
    /** The first problem with [entries], or null when they can all be saved. */
    fun validate(entries: List<PronunciationEntry>): PronunciationProblem? {
        val ids = mutableSetOf<String>()
        val words = mutableSetOf<String>()
        for (entry in entries) {
            if (!ids.add(entry.id.uppercase(Locale.ROOT)) || !words.add(entry.word.lowercase(Locale.ROOT))) {
                return PronunciationProblem.Duplicate
            }
            if (entry.word.isBlank() || entry.pronunciation.isBlank()) return PronunciationProblem.Empty
            if (entry.isRegex && compile(entry.word, entry.caseSensitive) == null) {
                return PronunciationProblem.InvalidPattern
            }
        }
        return null
    }

    /**
     * SpeakCore's `PronunciationRenderer.applyReplacements`: every entry with a non-empty replacement,
     * in order, each applied to the previous result. A case-sensitive word replaces every literal
     * occurrence; otherwise it matches case-insensitively between word boundaries and the replacement
     * is a template. A regular expression that does not compile leaves the text unchanged.
     */
    fun apply(text: String, entries: List<PronunciationEntry>): String = entries.fold(text) { result, entry ->
        val replacement = entry.replacement?.takeIf { it.isNotEmpty() } ?: return@fold result
        when {
            entry.isRegex -> replace(result, compile(entry.word, entry.caseSensitive), replacement)
            entry.caseSensitive -> result.replace(entry.word, replacement)
            else -> replace(result, compile("\\b${Regex.escape(entry.word)}\\b", caseSensitive = false), replacement)
        }
    }

    private fun replace(text: String, regex: Regex?, template: String): String {
        if (regex == null) return text
        return try {
            regex.replace(text, template)
        } catch (_: IllegalArgumentException) {
            // A template naming a group the pattern lacks; leave the text as it is.
            text
        } catch (_: IndexOutOfBoundsException) {
            text
        }
    }

    private fun compile(pattern: String, caseSensitive: Boolean): Regex? = try {
        if (caseSensitive) Regex(pattern) else Regex(pattern, RegexOption.IGNORE_CASE)
    } catch (_: PatternSyntaxException) {
        null
    }
}
