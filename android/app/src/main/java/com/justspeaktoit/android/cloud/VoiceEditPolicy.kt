package com.justspeaktoit.android.cloud

/**
 * SpeakCore's `VoiceEditPolicy`: rewriting a selection by voice. The system prompt, the user message's
 * intro and the formatting words are generated from `assets/cloud_catalog.json`, so Android asks the
 * model exactly what every other platform asks. The response cleanup is a port of the Swift rules, kept
 * in step by `VoiceEditPolicyTest`.
 */
object VoiceEditPolicy {
    val systemPrompt: String get() = GeneratedCloudCatalog.VOICE_EDIT_SYSTEM_PROMPT

    /**
     * The selection and instruction as a JSON data object after the shared intro, so their contents
     * never become prompt structure. Encoded by hand to match Swift's `JSONEncoder` byte for byte
     * (sorted keys, escaped slashes), which `org.json` does not promise.
     */
    fun userMessage(selection: String, instruction: String): String =
        GeneratedCloudCatalog.VOICE_EDIT_USER_MESSAGE_INTRO + "\n\n" +
            "{\"instruction\":" + jsonString(instruction) + ",\"selectedText\":" + jsonString(selection) + "}"

    /** Cleans a recognised spoken instruction before it is sent to the model. */
    fun normalizedInstruction(raw: String): String = raw.trim()

    /**
     * Removes only provably accidental wrappers from the model's reply: outer whitespace the selection
     * did not have, a wrapping code fence and symmetric wrapping quotes the selection did not have.
     * Formatting the instruction asked for is kept.
     */
    fun normalizedRewrite(raw: String, original: String, instruction: String = ""): String {
        val intent = VoiceEditFormattingIntent.of(instruction)
        var text = if (intent.requestsWhitespace) raw else trimAccidentalWhitespace(raw, original)
        if (!intent.requestsCodeFence) text = stripCodeFence(text, original)
        if (!intent.requestsQuotes) text = stripWrappingQuotes(text, original)
        return text
    }

    private fun trimAccidentalWhitespace(text: String, original: String): String {
        var result = text
        if (original.firstOrNull()?.isWhitespace() != true) result = result.trimStart()
        if (original.lastOrNull()?.isWhitespace() != true) result = result.trimEnd()
        return result
    }

    private fun stripCodeFence(text: String, original: String): String {
        if (!text.startsWith(FENCE) || !text.endsWith(FENCE) || original.startsWith(FENCE)) return text
        val lines = text.split("\n")
        if (lines.size < 2) return text
        // Only the fence's own line breaks are accidental; indentation inside it is content.
        return lines.subList(1, lines.size - 1).joinToString("\n").trim { it in NEWLINES }
    }

    private fun stripWrappingQuotes(text: String, original: String): String {
        if (text.length < 2) return text
        for ((opening, closing) in QUOTE_PAIRS) {
            if (text.first() != opening || text.last() != closing) continue
            if (original.firstOrNull() == opening && original.lastOrNull() == closing) continue
            val inner = text.substring(1, text.length - 1)
            // `"alpha" and "beta"` starts and ends with a quote without being wrapped in one.
            if (opening in inner || closing in inner) continue
            return inner.trim()
        }
        return text
    }

    private fun jsonString(value: String): String = buildString {
        append('"')
        for (c in value) {
            when (c) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '/' -> append("\\/")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                '\b' -> append("\\b")
                '\u000C' -> append("\\f")
                else -> if (c < ' ') append("\\u").append(c.code.toString(HEX).padStart(4, '0')) else append(c)
            }
        }
        append('"')
    }

    private const val HEX = 16
    private const val FENCE = "```"
    private const val NEWLINES = "\n\r\u000B\u000C\u0085\u2028\u2029"
    private val QUOTE_PAIRS = listOf('"' to '"', '\'' to '\'', '\u201C' to '\u201D', '\u2018' to '\u2019')
}

/** Output formatting the spoken instruction asked for, so cleanup removes only what the model added. */
data class VoiceEditFormattingIntent(
    val requestsQuotes: Boolean,
    val requestsCodeFence: Boolean,
    val requestsWhitespace: Boolean,
) {
    companion object {
        fun of(instruction: String): VoiceEditFormattingIntent {
            val lowered = instruction.lowercase()
            fun mentions(terms: List<String>) = terms.any { lowered.contains(it) }
            return VoiceEditFormattingIntent(
                requestsQuotes = mentions(GeneratedCloudCatalog.VOICE_EDIT_QUOTE_TERMS),
                requestsCodeFence = mentions(GeneratedCloudCatalog.VOICE_EDIT_CODE_FENCE_TERMS),
                requestsWhitespace = mentions(GeneratedCloudCatalog.VOICE_EDIT_WHITESPACE_TERMS),
            )
        }
    }
}
