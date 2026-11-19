package com.justspeaktoit.android.history

import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale

/**
 * What History shows: the Android counterpart of the shared `HistorySearchQuery`
 * (`Sources/SpeakCore/History/HistoryPresentation.swift`). It only narrows the visible list and never
 * changes stored entries. Either day may be left open, as on Windows and Linux.
 */
data class HistoryFilter(
    val searchText: String = "",
    /** A [modelKey]; null shows every model. */
    val model: String? = null,
    val errorsOnly: Boolean = false,
    val fromDay: LocalDate? = null,
    val throughDay: LocalDate? = null,
) {
    val isActive: Boolean
        get() = searchText.isNotBlank() || model != null || errorsOnly || fromDay != null || throughDay != null

    /**
     * The entries that satisfy every active constraint, in their stored order. [modelName] gives the
     * friendly name of a [modelKey], which search matches as well as the key itself.
     */
    fun matching(
        entries: List<HistoryEntry>,
        zone: ZoneId = ZoneId.systemDefault(),
        modelName: (String) -> String = { it },
    ): List<HistoryEntry> {
        if (!isActive) return entries
        val term = searchText.trim().lowercase(Locale.ROOT)
        val requestedModel = model?.lowercase(Locale.ROOT)
        val range = dayRange(zone)
        return entries.filter { entry ->
            val key = modelKey(entry)
            val matchesSearch = term.isEmpty() ||
                entry.text.lowercase(Locale.ROOT).contains(term) ||
                key.lowercase(Locale.ROOT).contains(term) ||
                modelName(key).lowercase(Locale.ROOT).contains(term)
            matchesSearch &&
                (requestedModel == null || key.lowercase(Locale.ROOT) == requestedModel) &&
                (!errorsOnly || hasError(entry)) &&
                (range == null || entry.createdAtMs in range)
        }
    }

    /** The inclusive millisecond range the chosen days cover in [zone], or null when no day is chosen. */
    fun dayRange(zone: ZoneId): LongRange? {
        val from = fromDay
        val through = throughDay
        return when {
            from != null && through != null -> normalizedDayRange(from, through, zone)
            from != null -> normalizedDayRange(from, from, zone).first..Long.MAX_VALUE
            through != null -> Long.MIN_VALUE..normalizedDayRange(through, through, zone).last
            else -> null
        }
    }

    companion object {
        /** The model an entry is filtered by: its Cloud model, otherwise its recognition mode. */
        fun modelKey(entry: HistoryEntry): String = entry.model ?: entry.mode

        /** Every distinct [modelKey] in [entries], for the model picker. */
        fun models(entries: List<HistoryEntry>): List<String> = entries.map(::modelKey).distinct()

        /** A failed session, or a kept recording whose later transcription failed. */
        fun hasError(entry: HistoryEntry): Boolean = entry.status == HistoryStatus.Failed || entry.failure != null

        /**
         * The shared day policy (`HistorySearchQuery.normalizedDayRange`): from the start of [from] to one
         * second before the end of the later day, both in [zone], so it stays correct across
         * daylight-saving changes.
         */
        fun normalizedDayRange(from: LocalDate, through: LocalDate, zone: ZoneId): LongRange {
            val lower = from.atStartOfDay(zone).toInstant().toEpochMilli()
            val last = maxOf(from, through)
            val upper = last.plusDays(1).atStartOfDay(zone).minusSeconds(1).toInstant().toEpochMilli()
            return lower..upper
        }
    }
}
