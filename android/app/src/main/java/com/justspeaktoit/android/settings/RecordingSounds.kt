package com.justspeaktoit.android.settings

import androidx.annotation.RawRes
import com.justspeaktoit.android.R

/** The two moments a recording announces itself. */
enum class RecordingCue { Start, Stop }

/**
 * The four sound profiles, keyed by SpeakCore's `RecordingFeedbackProfile` raw values so the shared
 * `recordingSoundProfile` setting means the same thing on every platform. The sounds are the shared
 * files in `Resources/Sounds`, copied byte for byte into `res/raw` (SpeakCore's parity test checks).
 */
enum class RecordingSoundProfile(
    val id: String,
    val displayName: String,
    @RawRes private val start: Int,
    @RawRes private val stop: Int,
) {
    Classic("classic", "Classic", R.raw.recording_start, R.raw.recording_stop),
    Bubbly("bubbly", "Bubbly", R.raw.recording_start_bubbly, R.raw.recording_stop_bubbly),
    Futuristic("futuristic", "Futuristic", R.raw.recording_start_futuristic, R.raw.recording_stop_futuristic),
    Soft("soft", "Soft", R.raw.recording_start_soft, R.raw.recording_stop_soft),
    ;

    @RawRes
    fun sound(cue: RecordingCue): Int = if (cue == RecordingCue.Start) start else stop

    companion object {
        /** An unknown or missing value falls back to the shared default rather than silencing cues. */
        fun fromId(id: String?): RecordingSoundProfile = entries.firstOrNull { it.id == id } ?: Classic
    }
}

/** The shared `recordingSoundsEnabled`, `recordingSoundProfile` and `recordingSoundVolume` settings. */
data class RecordingSoundSettings(
    val enabled: Boolean = DEFAULT_ENABLED,
    val profile: RecordingSoundProfile = RecordingSoundProfile.Classic,
    /** Within [VOLUME_RANGE], as the slider shows it. */
    val volume: Float = DEFAULT_VOLUME,
) {
    /** SpeakCore's `RecordingFeedbackDefaults.gain`: squared, so the quiet end of the slider is usable. */
    val gain: Float get() = volume.coerceIn(0f, 1f).let { it * it }

    companion object {
        const val DEFAULT_ENABLED = true
        const val DEFAULT_VOLUME = 0.7f

        /** SpeakCore's `RecordingFeedbackDefaults.volumeRange`: the quietest step stays audible. */
        val VOLUME_RANGE = 0.02f..1f

        fun clampVolume(volume: Float): Float = if (volume.isNaN()) DEFAULT_VOLUME else volume.coerceIn(VOLUME_RANGE)
    }
}
