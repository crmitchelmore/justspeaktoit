package com.justspeaktoit.android.dictation

import android.media.AudioRecord
import com.justspeaktoit.android.cloud.Microphone
import com.justspeaktoit.android.cloud.WavFormat
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The hands-free microphone: one [AudioRecord] read in 0.1 s chunks on its own thread, as
 * `WavRecorder` reads it, while hands-free is armed. [stop] only asks the thread to finish; the thread
 * releases the microphone after its current read, so the main thread never waits for it.
 * It listens on the system default microphone; each recording it starts uses the one chosen in Settings.
 */
internal class AudioRecordMicrophone : HandsFreeMicrophone {
    /** The current run's flag; each run has its own, so a late-finishing thread is never revived. */
    private var running: AtomicBoolean? = null
    private var thread: Thread? = null

    override fun start(onAudio: (ShortArray, Int) -> Unit, onFailed: () -> Unit): Boolean {
        // A microphone released a moment ago may still be closing; opening a second one could fail.
        thread?.join(PREVIOUS_STOP_WAIT_MS)
        val audio = Microphone.open() ?: return false
        val run = AtomicBoolean(true)
        running = run
        thread = Thread({ pump(audio, run, onAudio, onFailed) }, "jsti-hands-free").apply { start() }
        return true
    }

    private fun pump(
        audio: AudioRecord,
        active: AtomicBoolean,
        onAudio: (ShortArray, Int) -> Unit,
        onFailed: () -> Unit,
    ) {
        val chunk = ShortArray(WavFormat.SAMPLE_RATE / 10)
        try {
            while (active.get()) {
                val read = audio.read(chunk, 0, chunk.size)
                if (read < 0) {
                    if (active.get()) onFailed()
                    break
                }
                if (read > 0 && active.get()) onAudio(chunk, read)
            }
        } finally {
            runCatching { audio.stop() }
            audio.release()
        }
    }

    override fun stop() {
        running?.set(false)
        running = null
    }

    private companion object {
        const val PREVIOUS_STOP_WAIT_MS = 500L
    }
}
