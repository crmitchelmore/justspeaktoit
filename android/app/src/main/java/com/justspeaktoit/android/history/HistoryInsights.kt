package com.justspeaktoit.android.history

/** Dictation totals over a recent window, counted from completed History entries only. */
data class HistoryInsights(val dictations: Int, val words: Int) {
    companion object {
        const val WINDOW_DAYS = 7
        private const val DAY_MS = 24L * 60 * 60 * 1000
        private val whitespace = Regex("""\s+""")

        fun of(entries: List<HistoryEntry>, nowMs: Long, days: Int = WINDOW_DAYS): HistoryInsights {
            val since = nowMs - days * DAY_MS
            val recent = entries.filter {
                it.status == HistoryStatus.Completed && it.createdAtMs in since..nowMs && it.text.isNotBlank()
            }
            return HistoryInsights(
                dictations = recent.size,
                words = recent.sumOf { entry -> entry.text.trim().split(whitespace).size },
            )
        }
    }
}
