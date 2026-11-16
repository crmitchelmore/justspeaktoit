package com.justspeaktoit.android.dictation

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaMetadataRetriever
import android.media.SoundPool
import com.justspeaktoit.android.settings.RecordingCue
import com.justspeaktoit.android.settings.RecordingSoundProfile
import java.util.concurrent.ConcurrentHashMap

/** Plays the start and stop cues; [RecordingSoundPlayer] in production. */
interface RecordingSoundOutput {
    /** Plays [cue] from [profile] at [gain] (0 to 1) and returns how long it lasts in milliseconds. */
    fun play(cue: RecordingCue, profile: RecordingSoundProfile, gain: Float): Long

    fun close()
}

/**
 * Plays the shared cue files through [SoundPool], preloaded so a cue starts without decoding delay.
 * Cues are sonification, so they follow the system's notification-style volume rules and never take
 * audio focus from music the user is playing.
 */
class RecordingSoundPlayer(context: Context) : RecordingSoundOutput {
    private val context = context.applicationContext
    private val pool = SoundPool.Builder()
        .setMaxStreams(2)
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build(),
        )
        .build()
    private val loaded = ConcurrentHashMap<Int, Int>()
    private val durations = ConcurrentHashMap<Int, Long>()
    private val ready = ConcurrentHashMap.newKeySet<Int>()

    init {
        pool.setOnLoadCompleteListener { _, sampleId, status -> if (status == 0) ready += sampleId }
        val resources = RecordingSoundProfile.entries.flatMap { profile -> RecordingCue.entries.map(profile::sound) }
        resources.forEach(::load)
        // Read off the main thread, so the first cue need not wait for a metadata parse.
        Thread({ resources.forEach { durations.getOrPut(it) { duration(it) } } }, "jsti-cue-durations").start()
    }

    override fun play(cue: RecordingCue, profile: RecordingSoundProfile, gain: Float): Long {
        val resource = profile.sound(cue)
        val sample = load(resource)
        // A cue still decoding is skipped: a late start sound would land on the user's first words.
        if (sample !in ready) return 0
        val volume = gain.coerceIn(0f, 1f)
        if (pool.play(sample, volume, volume, 1, 0, 1f) == 0) return 0
        return durations.getOrPut(resource) { duration(resource) }
    }

    override fun close() {
        pool.release()
    }

    private fun load(resource: Int): Int = loaded.getOrPut(resource) { pool.load(context, resource, 1) }

    private fun duration(resource: Int): Long = runCatching {
        context.resources.openRawResourceFd(resource).use { fd ->
            MediaMetadataRetriever().use { retriever ->
                retriever.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
            }
        }
    }.getOrNull() ?: FALLBACK_DURATION_MS

    private companion object {
        /** Longer than every shared cue, so an unreadable duration still covers the sound. */
        const val FALLBACK_DURATION_MS = 400L
    }
}
