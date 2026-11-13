package com.justspeaktoit.android.corrections

import com.justspeaktoit.android.cloud.GeneratedCloudCatalog
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** One personal correction: whatever the recogniser writes as any of [heardAs] becomes [writeAs]. */
data class CorrectionRule(val writeAs: String, val heardAs: List<String>)

/**
 * Personal corrections and vocabulary, with the Mac lexicon's semantics: every alias is matched as a
 * whole word, ignoring case, and replaced with the rule's spelling. The spellings also form the
 * vocabulary glossary that cloud models with a `prompt` field receive.
 */
object PersonalCorrections {
    /** Applies [rules] in order, alias by alias, to a final transcript. */
    fun apply(text: String, rules: List<CorrectionRule>): String = rules.fold(text) { current, rule ->
        rule.heardAs.fold(current) { inner, alias ->
            val trimmed = alias.trim()
            if (trimmed.isEmpty()) {
                inner
            } else {
                Regex("""(?<!$WORD)${Regex.escape(trimmed)}(?!$WORD)""", setOf(RegexOption.IGNORE_CASE))
                    .replace(inner) { rule.writeAs }
            }
        }
    }

    /**
     * SpeakCore's `TranscriptionKeywordPolicy.prompt`: distinct terms, at most [maxTerms], joined with
     * ", " while the glossary stays within [maxBytes] UTF-8 bytes. Null when there is nothing to send.
     */
    fun vocabularyPrompt(
        words: List<String>,
        maxBytes: Int = GeneratedCloudCatalog.KEYWORD_PROMPT_MAX_BYTES,
        maxTerms: Int = GeneratedCloudCatalog.KEYWORD_PROMPT_MAX_TERMS,
    ): String? {
        val seen = mutableSetOf<String>()
        val terms = words.map { it.trim() }
            .filter { it.isNotEmpty() && it.utf8Size() <= maxBytes && seen.add(it.lowercase()) }
            .take(maxTerms)
        var result = ""
        for (term in terms) {
            val next = if (result.isEmpty()) term else "$result, $term"
            if (next.utf8Size() > maxBytes) break
            result = next
        }
        return result.ifEmpty { null }
    }

    fun vocabularyPrompt(rules: List<CorrectionRule>): String? = vocabularyPrompt(rules.map { it.writeAs })

    /** Builds a rule from the editor's fields; aliases are comma- or line-separated. Null when unusable. */
    fun rule(writeAs: String, heardAs: String): CorrectionRule? = rule(writeAs, heardAs.split(',', '\n'))

    private fun rule(writeAs: String, heardAs: List<String>): CorrectionRule? {
        val spelling = writeAs.trim()
        if (spelling.isEmpty()) return null
        val seen = mutableSetOf<String>()
        val aliases = heardAs.map { it.trim() }.filter { it.isNotEmpty() && it != spelling && seen.add(it.lowercase()) }
        return CorrectionRule(spelling, aliases)
    }

    fun encode(rules: List<CorrectionRule>): String = JSONArray().apply {
        rules.forEach { rule ->
            put(JSONObject().put("writeAs", rule.writeAs).put("heardAs", JSONArray(rule.heardAs)))
        }
    }.toString()

    /** Tolerates a damaged value: unreadable rules are skipped rather than losing the rest. */
    fun decode(json: String?): List<CorrectionRule> {
        if (json.isNullOrBlank()) return emptyList()
        val array = try {
            JSONArray(json)
        } catch (e: JSONException) {
            return emptyList()
        }
        return (0 until array.length()).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            val aliases = item.optJSONArray("heardAs") ?: JSONArray()
            rule(item.optString("writeAs"), (0 until aliases.length()).map { aliases.optString(it) })
        }
    }

    /** A letter, mark, digit or underscore in any script, so `café` is one word, not `caf` + `é`. */
    private const val WORD = """[\p{L}\p{M}\p{N}_]"""

    private fun String.utf8Size(): Int = toByteArray(Charsets.UTF_8).size
}
