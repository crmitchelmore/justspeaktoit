package com.justspeaktoit.android.readaloud

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
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

    /** How long one regular expression may run before it is skipped, so a pathological pattern cannot stall reading. */
    const val ENTRY_BUDGET_MS = 500L

    /**
     * SpeakCore's `PronunciationRenderer.applyReplacements`: every entry with a non-empty replacement,
     * in order, each applied to the previous result. A case-sensitive word replaces every literal
     * occurrence; otherwise it matches case-insensitively between word boundaries. Only a regular
     * expression's replacement is a template. A regular expression that does not compile, or that runs
     * past [entryBudgetMs], leaves the text unchanged. Blocks, so call it off the main thread.
     */
    fun apply(
        text: String,
        entries: List<PronunciationEntry>,
        entryBudgetMs: Long = ENTRY_BUDGET_MS,
        active: () -> Boolean = { true },
    ): String = entries.fold(text) { result, entry ->
        val replacement = entry.replacement?.takeIf { it.isNotEmpty() } ?: return@fold result
        if (!active()) return@fold result
        when {
            entry.isRegex -> {
                val regex = compile(entry.word, entry.caseSensitive) ?: return@fold result
                RegexWatchdog.run("${entry.caseSensitive}:${entry.word}", entryBudgetMs) {
                    val deadline = System.nanoTime() + entryBudgetMs * NANOS_PER_MS
                    replace(BoundedCharSequence(result, deadline, active), regex, replacement)
                } ?: result
            }
            entry.caseSensitive -> result.replace(entry.word, replacement)
            else -> {
                // An escaped word cannot backtrack badly, so it runs here; its replacement is literal.
                val regex = compile("\\b${Regex.escape(entry.word)}\\b", caseSensitive = false) ?: return@fold result
                replace(result, regex, Regex.escapeReplacement(replacement)) ?: result
            }
        }
    }

    /** Null when [template] names a group the pattern lacks, or the time limit stopped the match. */
    private fun replace(text: CharSequence, regex: Regex, template: String): String? = try {
        regex.replace(text, template)
    } catch (_: BoundedCharSequence.Expired) {
        null
    } catch (_: IllegalArgumentException) {
        null
    } catch (_: IndexOutOfBoundsException) {
        null
    }

    private const val NANOS_PER_MS = 1_000_000L

    private fun compile(pattern: String, caseSensitive: Boolean): Regex? = try {
        if (caseSensitive) Regex(pattern) else Regex(pattern, RegexOption.IGNORE_CASE)
    } catch (_: PatternSyntaxException) {
        null
    }
}

/**
 * Text that stops a regular expression reading it once [deadlineNanos] passes or [active] turns
 * false, by throwing [Expired] from [get]. The JVM's java.util.regex reads input through it, so the
 * match ends there; Android's ICU-backed regex copies the text first, so [RegexWatchdog] bounds it.
 */
internal class BoundedCharSequence(
    private val text: CharSequence,
    private val deadlineNanos: Long,
    private val active: () -> Boolean,
) : CharSequence {
    class Expired : RuntimeException(null, null, false, false)

    private var reads = 0

    override val length: Int get() = text.length

    override fun get(index: Int): Char {
        if ((reads++ and CHECK_MASK) == 0 && (System.nanoTime() - deadlineNanos > 0 || !active())) throw Expired()
        return text[index]
    }

    override fun subSequence(startIndex: Int, endIndex: Int): CharSequence = text.subSequence(startIndex, endIndex)

    override fun toString(): String = text.toString()

    private companion object {
        const val CHECK_MASK = 0xFF
    }
}

/**
 * Runs a user regular expression on a background thread and gives up after a time limit. Android's
 * regex engine cannot be interrupted, so a pattern that ran out of time is remembered and skipped
 * from then on rather than started again on every reading.
 */
internal object RegexWatchdog {
    private val slow: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val threads = Executors.newCachedThreadPool { task ->
        Thread(task, "jsti-pronunciation").apply {
            isDaemon = true
            priority = Thread.MIN_PRIORITY
        }
    }

    /** [block]'s result, or null when [key] timed out now or before, or [block] returned null. */
    fun run(key: String, budgetMs: Long, block: () -> String?): String? {
        if (key in slow) return null
        val task = threads.submit(Callable { block() })
        return try {
            task.get(budgetMs, TimeUnit.MILLISECONDS)
        } catch (_: TimeoutException) {
            slow += key
            task.cancel(true)
            null
        } catch (_: ExecutionException) {
            null
        } catch (_: InterruptedException) {
            task.cancel(true)
            Thread.currentThread().interrupt()
            null
        }
    }
}
