package com.justspeaktoit.android.history

/**
 * Usage totals over every History entry, as SpeakCore's `HistoryPresentationStatistics` counts them on
 * the Mac and iPhone: each entry is a session, an entry with a failure is a session with errors, and
 * words are counted in the cleaned text (the raw transcript when there is none).
 */
data class UsageInsights(
    val sessions: Int,
    val sessionsWithErrors: Int,
    val recordingSeconds: Double,
    val averageSessionSeconds: Double,
    val words: Int,
) {
    companion object {
        fun of(entries: List<HistoryEntry>): UsageInsights {
            val recording = entries.sumOf { maxOf(0.0, it.durationSeconds ?: 0.0) }
            return UsageInsights(
                sessions = entries.size,
                sessionsWithErrors = entries.count(HistoryFilter::hasError),
                recordingSeconds = recording,
                averageSessionSeconds = if (entries.isEmpty()) 0.0 else recording / entries.size,
                words = entries.sumOf(::wordCount),
            )
        }

        private fun wordCount(entry: HistoryEntry): Int {
            val text = entry.text.trim().ifEmpty { entry.rawText?.trim().orEmpty() }
            return text.indices.count { index ->
                !text[index].isWhitespace() && (index == 0 || text[index - 1].isWhitespace())
            }
        }
    }
}
