package com.justspeaktoit.android.dictation

/**
 * Silence auto-stop for a manual Cloud recording (issue #1632). These are the shared
 * `silenceDetectionEnabled`, `silenceThreshold` and `silenceDuration` settings, with SpeakCore's
 * `DictationSilencePolicy` defaults and ranges. The platform recognisers end on a pause by
 * themselves, so only Cloud capture needs it.
 */
data class SilenceSettings(
    val enabled: Boolean = false,
    /** SpeakCore's 0..1 input level below which audio counts as silence; lower is more sensitive. */
    val threshold: Double = DEFAULT_THRESHOLD,
    val durationSeconds: Double = DEFAULT_DURATION,
) {
    companion object {
        const val DEFAULT_THRESHOLD = 0.05
        const val DEFAULT_DURATION = 2.0
        val THRESHOLD_RANGE = 0.01..0.2
        val DURATION_RANGE = 0.5..5.0

        /** Clamps stored or edited values into the shared ranges; a value that is not a number becomes the default. */
        fun of(enabled: Boolean, threshold: Double, durationSeconds: Double) = SilenceSettings(
            enabled = enabled,
            threshold = if (threshold.isNaN()) DEFAULT_THRESHOLD else threshold.coerceIn(THRESHOLD_RANGE),
            durationSeconds = if (durationSeconds.isNaN()) DEFAULT_DURATION else durationSeconds.coerceIn(DURATION_RANGE),
        )
    }
}

/**
 * SpeakCore's `DictationSilenceMonitor`: quiet from the start of the recording counts too, and it
 * fires once. Fed from the capture thread; time is seconds of audio captured, so a paused capture
 * (which reports a level that is not a number) neither advances nor resets the silence.
 */
internal class SilenceMonitor(private val threshold: Double, private val durationSeconds: Double) {
    private var silentSince: Double? = null
    private var stopped = false

    @Synchronized
    fun observe(level: Double, atSeconds: Double): Boolean {
        if (stopped || !level.isFinite() || !atSeconds.isFinite()) return false
        if (level >= threshold) {
            silentSince = null
            return false
        }
        val since = silentSince
        if (since == null || atSeconds < since) {
            silentSince = atSeconds
            return false
        }
        if (atSeconds - since < durationSeconds) return false
        stopped = true
        return true
    }
}
