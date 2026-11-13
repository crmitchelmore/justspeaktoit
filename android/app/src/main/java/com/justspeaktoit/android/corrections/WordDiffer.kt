package com.justspeaktoit.android.corrections

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** SpeakCore's `WordChange.ChangeType`. */
enum class WordChangeType { Replacement, Split, Merge }

/** One word-level change between inserted and edited text; SpeakCore's `WordChange`. */
data class WordChange(val type: WordChangeType, val original: String, val corrected: String) {
    /** Whether this looks like a correction rather than a rewrite, with SpeakCore's rules. */
    val isLikelyCorrection: Boolean
        get() {
            val origLower = original.lowercase()
            val corrLower = corrected.lowercase()
            if (original.characterCount() < 2 || corrected.characterCount() < 2) return false
            if (original == corrected) return false
            return when (type) {
                // Over 30% similar catches typos like Suzy → Susie; a case-only change (speak → Speak) counts.
                WordChangeType.Replacement -> similarity(origLower, corrLower) > 0.3 || origLower == corrLower
                // "gonna" → "going to": the original starts like the first corrected word.
                WordChangeType.Split -> {
                    val firstWord = corrected.split(' ').firstOrNull() ?: return true
                    origLower.startsWith(firstWord.take(2).lowercase())
                }
                // "can not" → "cannot": the corrected word contains every original word.
                WordChangeType.Merge -> original.split(' ').all { corrLower.contains(it.lowercase()) }
            }
        }

    /** Positional character matches over the longer length, or 0.7 when one contains the other. */
    private fun similarity(lhs: String, rhs: String): Double {
        val lhsChars = lhs.codePoints().toArray()
        val rhsChars = rhs.codePoints().toArray()
        val maxLen = max(lhsChars.size, rhsChars.size)
        if (maxLen == 0) return 1.0
        val matches = (0 until min(lhsChars.size, rhsChars.size)).count { lhsChars[it] == rhsChars[it] }
        if (lhs.contains(rhs) || rhs.contains(lhs)) return 0.7
        return matches.toDouble() / maxLen
    }
}

/**
 * SpeakCore's `WordDiffer`: finds direct word replacements between inserted and edited text, and
 * nothing for a rewrite. `WordDifferParityTest` pins the shared cases; change both together.
 */
object WordDiffer {
    const val MINIMUM_WORD_LENGTH = 2

    fun findChanges(original: String, edited: String): List<WordChange> {
        val originalWords = tokenize(original)
        val editedWords = tokenize(edited)
        if (originalWords.isEmpty() || editedWords.isEmpty()) return emptyList()

        val (prefixLen, suffixLen) = commonEnds(
            originalWords.map { it.lowercase() },
            editedWords.map { it.lowercase() },
        )
        val originalMiddle = originalWords.subList(prefixLen, originalWords.size - suffixLen)
        val editedMiddle = editedWords.subList(prefixLen, editedWords.size - suffixLen)
        if (originalMiddle.isEmpty() && editedMiddle.isEmpty()) return emptyList()

        // More than 5 words' difference, or more than 10 changed words, is a rewrite.
        if (abs(originalMiddle.size - editedMiddle.size) > 5) return emptyList()
        if (originalMiddle.size > 10 || editedMiddle.size > 10) return emptyList()
        return wordChanges(originalMiddle, editedMiddle)
    }

    /** Words split on whitespace, with leading and trailing punctuation trimmed. */
    private fun tokenize(text: String): List<String> {
        val words = mutableListOf<String>()
        val current = StringBuilder()
        fun flush() {
            val word = current.toString().trim { it.category in PUNCTUATION }
            if (word.isNotEmpty()) words += word
            current.setLength(0)
        }
        text.forEach { if (it.isWhitespace()) flush() else current.append(it) }
        flush()
        return words
    }

    /** Common prefix length, then common suffix length not overlapping it, of lowercased words. */
    private fun commonEnds(lhs: List<String>, rhs: List<String>): Pair<Int, Int> {
        val minLen = min(lhs.size, rhs.size)
        var prefixLen = 0
        while (prefixLen < minLen && lhs[prefixLen] == rhs[prefixLen]) prefixLen++
        var suffixLen = 0
        val maxSuffix = minLen - prefixLen
        while (suffixLen < maxSuffix && lhs[lhs.size - 1 - suffixLen] == rhs[rhs.size - 1 - suffixLen]) suffixLen++
        return prefixLen to suffixLen
    }

    private fun wordChanges(original: List<String>, edited: List<String>): List<WordChange> = when {
        // Same word count: 1:1 replacements, including case-only changes (speak → Speak).
        original.size == edited.size -> original.zip(edited).mapNotNull { (orig, edit) ->
            if (orig != edit && orig.isLongEnough() && edit.isLongEnough()) {
                WordChange(WordChangeType.Replacement, orig, edit).takeIf { it.isLikelyCorrection }
            } else {
                null
            }
        }
        // One word became two or three ("gonna" → "going to").
        original.size == 1 && edited.size in 2..3 -> listOfNotNull(
            WordChange(WordChangeType.Split, original[0], edited.joinToString(" ")).takeIf { it.isLikelyCorrection },
        )
        // Two or three words became one ("can not" → "cannot").
        original.size in 2..3 && edited.size == 1 -> listOfNotNull(
            WordChange(WordChangeType.Merge, original.joinToString(" "), edited[0]).takeIf { it.isLikelyCorrection },
        )
        else -> changesViaLcs(original, edited)
    }

    /** Aligns words by longest common subsequence; up to three changed words each side pair up 1:1. */
    private fun changesViaLcs(original: List<String>, edited: List<String>): List<WordChange> {
        if (original.isEmpty() || edited.isEmpty()) return emptyList()
        val originalLower = original.map { it.lowercase() }
        val editedLower = edited.map { it.lowercase() }
        val rows = originalLower.size
        val cols = editedLower.size
        val table = Array(rows + 1) { IntArray(cols + 1) }
        for (row in 0 until rows) {
            for (col in 0 until cols) {
                table[row + 1][col + 1] = if (originalLower[row] == editedLower[col]) {
                    table[row][col] + 1
                } else {
                    max(table[row][col + 1], table[row + 1][col])
                }
            }
        }
        val commonOriginal = mutableSetOf<Int>()
        val commonEdited = mutableSetOf<Int>()
        var row = rows
        var col = cols
        while (row > 0 && col > 0) {
            when {
                originalLower[row - 1] == editedLower[col - 1] -> {
                    commonOriginal += row - 1
                    commonEdited += col - 1
                    row--
                    col--
                }
                table[row - 1][col] > table[row][col - 1] -> row--
                else -> col--
            }
        }
        val changedOriginal = original.filterIndexed { index, _ -> index !in commonOriginal }
        val changedEdited = edited.filterIndexed { index, _ -> index !in commonEdited }
        if (changedOriginal.size != changedEdited.size || changedOriginal.size > 3) return emptyList()
        return changedOriginal.zip(changedEdited).mapNotNull { (orig, edit) ->
            if (orig.isLongEnough() && edit.isLongEnough()) {
                WordChange(WordChangeType.Replacement, orig, edit).takeIf { it.isLikelyCorrection }
            } else {
                null
            }
        }
    }

    private fun String.isLongEnough() = characterCount() >= MINIMUM_WORD_LENGTH

    private val PUNCTUATION = setOf(
        CharCategory.CONNECTOR_PUNCTUATION,
        CharCategory.DASH_PUNCTUATION,
        CharCategory.START_PUNCTUATION,
        CharCategory.END_PUNCTUATION,
        CharCategory.INITIAL_QUOTE_PUNCTUATION,
        CharCategory.FINAL_QUOTE_PUNCTUATION,
        CharCategory.OTHER_PUNCTUATION,
    )
}

/** Characters as a person counts them (code points), close to Swift's `String.count`. */
private fun String.characterCount(): Int = codePointCount(0, length)
