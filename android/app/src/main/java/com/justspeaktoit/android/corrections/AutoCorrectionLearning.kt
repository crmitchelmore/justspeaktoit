package com.justspeaktoit.android.corrections

import com.justspeaktoit.android.settings.DictationPreferences
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.UUID

/** SpeakCore's `AutoCorrectionLearningPolicy`. */
object AutoCorrectionLearningPolicy {
    const val ENABLED_BY_DEFAULT = true
    const val DEFAULT_PROMOTION_THRESHOLD = 2
    val PROMOTION_THRESHOLD_RANGE = 2..10
    const val MAXIMUM_UTF16_UNITS = 8_192

    /** How long the field is watched: 10 seconds plus one per sentence ending, at most 30. */
    fun observationSeconds(text: String): Int = minOf(10 + sentenceCount(text), 30)

    fun sentenceCount(text: String): Int = text.count { it == '.' || it == '!' || it == '?' }

    fun clampThreshold(value: Int): Int =
        value.coerceIn(PROMOTION_THRESHOLD_RANGE.first, PROMOTION_THRESHOLD_RANGE.last)
}

/**
 * SpeakCore's `AutoCorrectionCandidate`: an edit seen after insertion, counted until it is promoted
 * to a personal correction. A dismissed candidate is kept, hidden, so the same edit is not suggested again.
 */
data class AutoCorrectionCandidate(
    val id: String,
    val original: String,
    val corrected: String,
    val seenCount: Int = 1,
    val firstSeenAt: Long,
    val lastSeenAt: Long,
    val sourceApps: Set<String> = emptySet(),
    val dismissed: Boolean = false,
) {
    /** Identifies the same edit regardless of case. */
    val matchKey: String get() = matchKey(original, corrected)

    companion object {
        fun matchKey(original: String, corrected: String) = "${original.lowercase()}→${corrected.lowercase()}"

        /** Most stored candidates; the least recently seen go first, so storage stays bounded. */
        const val MAX_STORED = 500

        fun encode(candidates: List<AutoCorrectionCandidate>): String = JSONArray().apply {
            candidates.forEach { candidate ->
                put(
                    JSONObject()
                        .put("id", candidate.id)
                        .put("original", candidate.original)
                        .put("corrected", candidate.corrected)
                        .put("seenCount", candidate.seenCount)
                        .put("firstSeenAt", candidate.firstSeenAt)
                        .put("lastSeenAt", candidate.lastSeenAt)
                        .put("sourceApps", JSONArray(candidate.sourceApps.sorted()))
                        .put("dismissed", candidate.dismissed),
                )
            }
        }.toString()

        /** Tolerates a damaged value: unreadable or invalid candidates are skipped rather than losing the rest. */
        fun decode(json: String?): List<AutoCorrectionCandidate> {
            if (json.isNullOrBlank()) return emptyList()
            val array = try {
                JSONArray(json)
            } catch (e: JSONException) {
                return emptyList()
            }
            val ids = mutableSetOf<String>()
            return (0 until array.length()).mapNotNull { index ->
                val item = array.optJSONObject(index) ?: return@mapNotNull null
                val apps = item.optJSONArray("sourceApps") ?: JSONArray()
                AutoCorrectionCandidate(
                    id = item.optString("id"),
                    original = item.optString("original"),
                    corrected = item.optString("corrected"),
                    seenCount = item.optInt("seenCount"),
                    firstSeenAt = item.optLong("firstSeenAt"),
                    lastSeenAt = item.optLong("lastSeenAt"),
                    sourceApps = (0 until apps.length()).map { apps.optString(it) }.filter { it.isNotEmpty() }.toSet(),
                    dismissed = item.optBoolean("dismissed"),
                ).takeIf {
                    it.id.isNotEmpty() && it.seenCount > 0 && it.original.isNotBlank() && it.corrected.isNotBlank() &&
                        ids.add(it.id)
                }
            }
        }
    }
}

/**
 * SpeakCore's `AutoCorrectionDomain` over the app's preferences: a repeated edit is counted, and at
 * the promotion threshold it becomes a personal correction, which then applies to every transcript.
 * Accepting promotes a candidate at once; dismissing hides it for good.
 */
class AutoCorrectionLearner(
    private val prefs: DictationPreferences,
    private val clock: () -> Long = System::currentTimeMillis,
    private val newId: () -> String = { UUID.randomUUID().toString() },
) {
    /** Candidates waiting for review, oldest first. */
    fun pending(): List<AutoCorrectionCandidate> = prefs.correctionCandidates.filterNot { it.dismissed }

    /**
     * Records the user's edit of text the app inserted. Returns true when a candidate was counted or a
     * correction learned; a rewrite, an unchanged text or text over the size limit records nothing.
     */
    fun recordEdit(original: String, edited: String, app: String?): Boolean {
        if (original.isEmpty() || edited == original) return false
        val limit = AutoCorrectionLearningPolicy.MAXIMUM_UTF16_UNITS
        if (original.length > limit || edited.length > limit) return false
        val changes = WordDiffer.findChanges(original, edited)
        if (changes.isEmpty()) return false

        val threshold = AutoCorrectionLearningPolicy.clampThreshold(prefs.correctionPromotionThreshold)
        val sourceApp = app?.takeIf { it.isNotEmpty() }
        val now = clock()
        val candidates = prefs.correctionCandidates.toMutableList()
        val savedRules = prefs.corrections
        var rules = savedRules
        for (change in changes) {
            val key = AutoCorrectionCandidate.matchKey(change.original, change.corrected)
            val index = candidates.indexOfFirst { it.matchKey == key }
            if (index < 0) {
                candidates += AutoCorrectionCandidate(
                    id = newId(),
                    original = change.original,
                    corrected = change.corrected,
                    firstSeenAt = now,
                    lastSeenAt = now,
                    sourceApps = setOfNotNull(sourceApp),
                )
                continue
            }
            val existing = candidates[index]
            if (existing.dismissed) continue
            val seen = existing.copy(
                seenCount = existing.seenCount + 1,
                lastSeenAt = now,
                sourceApps = existing.sourceApps + setOfNotNull(sourceApp),
            )
            if (seen.seenCount >= threshold) {
                rules = promoted(rules, seen)
                candidates.removeAt(index)
            } else {
                candidates[index] = seen
            }
        }
        if (rules != savedRules) prefs.corrections = rules
        prefs.correctionCandidates = bounded(candidates)
        return true
    }

    /** Adds the candidate as a personal correction now. Returns false when it no longer exists. */
    fun accept(id: String): Boolean {
        val candidates = prefs.correctionCandidates
        val candidate = candidates.firstOrNull { it.id == id && !it.dismissed } ?: return false
        val rules = prefs.corrections
        val updated = promoted(rules, candidate)
        if (updated != rules) prefs.corrections = updated
        prefs.correctionCandidates = candidates.filterNot { it.id == id }
        return true
    }

    fun dismiss(id: String) {
        prefs.correctionCandidates = prefs.correctionCandidates.map {
            if (it.id == id) it.copy(dismissed = true) else it
        }
    }

    /** Forgets every candidate, including dismissed ones. Learned corrections stay. */
    fun clear() {
        prefs.correctionCandidates = emptyList()
    }

    private fun bounded(candidates: List<AutoCorrectionCandidate>): List<AutoCorrectionCandidate> {
        if (candidates.size <= AutoCorrectionCandidate.MAX_STORED) return candidates
        val kept = candidates.sortedByDescending { it.lastSeenAt }.take(AutoCorrectionCandidate.MAX_STORED).toSet()
        return candidates.filter { it in kept }
    }

    companion object {
        /**
         * [rules] with [candidate] learned: unchanged when a rule already writes its correction for its
         * original (ignoring case), otherwise the original joins the rule with the same spelling or a new
         * rule is added at the end.
         */
        fun promoted(rules: List<CorrectionRule>, candidate: AutoCorrectionCandidate): List<CorrectionRule> {
            val writeAs = candidate.corrected.trim()
            val heardAs = candidate.original.trim()
            if (writeAs.isEmpty() || heardAs.isEmpty() || writeAs == heardAs) return rules
            val known = rules.any { rule ->
                rule.writeAs.equals(writeAs, ignoreCase = true) &&
                    rule.heardAs.any { it.equals(heardAs, ignoreCase = true) }
            }
            if (known) return rules
            val index = rules.indexOfFirst { it.writeAs == writeAs }
            if (index < 0) return rules + CorrectionRule(writeAs, listOf(heardAs))
            return rules.mapIndexed { i, rule -> if (i == index) rule.copy(heardAs = rule.heardAs + heardAs) else rule }
        }
    }
}
