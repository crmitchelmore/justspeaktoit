package com.justspeaktoit.android.ui

import android.media.AudioAttributes
import android.media.MediaPlayer
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.IOException

/**
 * Plays one History recording at a time, on the main thread. Starting another recording stops the
 * current one; [stop] releases the player, so History calls it when it closes.
 */
internal class HistoryAudioPlayer {
    /** The recording now playing, if any. */
    var playingPath by mutableStateOf<String?>(null)
        private set

    /** The recording that last failed to play, so its entry can say so. */
    var failedPath by mutableStateOf<String?>(null)
        private set

    private var player: MediaPlayer? = null

    /** Plays [path], or stops it when it is the one playing. */
    fun toggle(path: String) {
        val wasPlaying = playingPath == path
        stop()
        if (wasPlaying) return
        failedPath = null
        val next = MediaPlayer()
        try {
            next.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            next.setDataSource(path)
            next.setOnCompletionListener { if (player === it) stop() }
            next.setOnErrorListener { mp, _, _ ->
                if (player === mp) {
                    stop()
                    failedPath = path
                }
                true
            }
            // A short local WAV file, so preparing it synchronously is quick.
            next.prepare()
            next.start()
        } catch (e: IOException) {
            return fail(next, path)
        } catch (e: IllegalArgumentException) {
            return fail(next, path)
        } catch (e: IllegalStateException) {
            return fail(next, path)
        } catch (e: SecurityException) {
            return fail(next, path)
        }
        player = next
        playingPath = path
    }

    fun stop() {
        player?.release()
        player = null
        playingPath = null
    }

    private fun fail(next: MediaPlayer, path: String) {
        next.release()
        failedPath = path
    }
}
