package com.justspeaktoit.android.corrections

/** The field an observation belongs to; the keyboard builds it from the editor's `EditorInfo`. */
data class EditorKey(val packageName: String?, val fieldId: Int, val inputType: Int)

/**
 * The text either side of an insertion when it was made. An empty side that was read short means the
 * insertion touched that end of the field.
 */
data class CorrectionContext(val before: String, val after: String, val atStart: Boolean, val atEnd: Boolean) {
    companion object {
        /** [before] and [after] as read, at most [CorrectionSpan.CONTEXT_LENGTH] characters each. */
        fun of(before: String, after: String): CorrectionContext {
            val length = CorrectionSpan.CONTEXT_LENGTH
            return CorrectionContext(
                before = before.takeLast(length),
                after = after.take(length),
                atStart = before.length < length,
                atEnd = after.length < length,
            )
        }
    }
}

/** Text read around the cursor later, and whether the reads reached the start and end of the field. */
data class TextWindow(val text: String, val reachesStart: Boolean, val reachesEnd: Boolean)

/** A committed transcript being watched in [editor] for the user's edits. */
data class CorrectionWatch(
    val original: String,
    val context: CorrectionContext,
    val editor: EditorKey,
    val app: String?,
)

/**
 * Finds what became of an inserted transcript: the text now between the context remembered either
 * side of it. Any doubt (a context missing, found more than once, or a span over the size limit)
 * returns null, so an edit is never attributed to the wrong text.
 */
object CorrectionSpan {
    /** Characters remembered either side of an insertion. */
    const val CONTEXT_LENGTH = 32

    /** Characters read either side of the cursor when sampling, enough for a full-size span and its context. */
    const val WINDOW_LENGTH = AutoCorrectionLearningPolicy.MAXIMUM_UTF16_UNITS + CONTEXT_LENGTH

    fun locate(
        window: TextWindow,
        context: CorrectionContext,
        maxLength: Int = AutoCorrectionLearningPolicy.MAXIMUM_UTF16_UNITS,
    ): String? {
        val text = window.text
        val start = if (context.atStart) {
            if (!window.reachesStart || !text.startsWith(context.before)) return null
            context.before.length
        } else {
            val index = text.uniqueIndexOf(context.before) ?: return null
            index + context.before.length
        }
        val end = if (context.atEnd) {
            if (!window.reachesEnd || !text.endsWith(context.after)) return null
            text.length - context.after.length
        } else {
            text.uniqueIndexOf(context.after) ?: return null
        }
        if (end < start || end - start > maxLength) return null
        return text.substring(start, end)
    }

    /** The index of [needle] when it occurs exactly once, overlaps included; null otherwise. */
    private fun String.uniqueIndexOf(needle: String): Int? {
        if (needle.isEmpty()) return null
        val first = indexOf(needle)
        if (first < 0 || indexOf(needle, first + 1) >= 0) return null
        return first
    }
}
