package com.justspeaktoit.android.cloud

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.log10
import kotlin.math.sqrt

/** 16 kHz mono PCM WAV header, the format every supported cloud model accepts. */
object WavFormat {
    const val SAMPLE_RATE = 16_000
    const val CHANNELS = 1
    const val BITS = 16
    const val HEADER_BYTES = 44
    const val BYTES_PER_SECOND = SAMPLE_RATE * CHANNELS * BITS / 8

    fun header(dataBytes: Long): ByteArray {
        require(dataBytes in 0..UInt.MAX_VALUE.toLong() - 36) { "Recording too large for WAV" }
        return ByteBuffer.allocate(HEADER_BYTES).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray())
            putInt((36 + dataBytes).toInt())
            put("WAVE".toByteArray())
            put("fmt ".toByteArray())
            putInt(16)
            putShort(1)
            putShort(CHANNELS.toShort())
            putInt(SAMPLE_RATE)
            putInt(BYTES_PER_SECOND)
            putShort((CHANNELS * BITS / 8).toShort())
            putShort(BITS.toShort())
            put("data".toByteArray())
            putInt(dataBytes.toInt())
        }.array()
    }

    /** Maps PCM loudness onto the -2..10 range SpeechRecognizer reports, so one meter fits both. */
    fun level(samples: ShortArray, count: Int): Float {
        if (count <= 0) return -2f
        var sum = 0.0
        for (i in 0 until count) {
            val s = samples[i].toDouble()
            sum += s * s
        }
        val rms = sqrt(sum / count) / Short.MAX_VALUE
        val dbfs = if (rms <= 0.0) -60.0 else (20 * log10(rms)).coerceIn(-60.0, 0.0)
        return ((dbfs + 60.0) / 5.0 - 2.0).toFloat()
    }
}

/** A microphone capture to one file; [WavRecorder] in production. */
interface AudioRecorder {
    /** Returns false when the microphone cannot be opened. */
    fun start(): Boolean

    /** Stops capture and returns the audio bytes recorded, or -1 if capture failed. Idempotent; may block. */
    fun stop(): Long

    /** Also hands each captured chunk of 16 kHz PCM16 to [sink], on the capture thread. Call before [start]. */
    fun tap(sink: (ByteArray) -> Unit) = Unit

    /** While paused the microphone stays open but nothing is written, so the file holds no gap noise. */
    fun setPaused(paused: Boolean) = Unit

    /** Records silence for the next [millis], so a cue the app plays is not captured into the audio. */
    fun mute(millis: Long) {}
}

/** Creates the recorder for each Cloud session. */
fun interface RecorderFactory {
    fun create(
        file: File,
        onLevel: (Float) -> Unit,
        onLimitReached: () -> Unit,
        onCaptureFailed: () -> Unit,
    ): AudioRecorder
}

/**
 * Captures microphone audio to a WAV file on a dedicated thread. Capture stops automatically at
 * [maxSeconds] so an upload stays within provider size limits.
 */
class WavRecorder(
    private val file: File,
    private val onLevel: (Float) -> Unit,
    private val onLimitReached: () -> Unit,
    /** Called on the capture thread when the microphone or disk fails mid-recording. */
    private val onCaptureFailed: () -> Unit,
    private val maxSeconds: Int = 600,
) : AudioRecorder {
    @Volatile private var running = false

    @Volatile private var failed = false

    @Volatile private var sink: ((ByteArray) -> Unit)? = null
    @Volatile private var paused = false
    /** [System.nanoTime] until which captured chunks are written as silence. */
    @Volatile private var mutedUntil = 0L
    private var thread: Thread? = null
    private var record: AudioRecord? = null

    override fun tap(sink: (ByteArray) -> Unit) {
        this.sink = sink
    }

    /** Returns false when the microphone cannot be opened. Requires RECORD_AUDIO. */
    @SuppressLint("MissingPermission")
    override fun start(): Boolean {
        val minBuffer = AudioRecord.getMinBufferSize(
            WavFormat.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) return false
        val audio = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                WavFormat.SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuffer, WavFormat.BYTES_PER_SECOND / 5),
            )
        } catch (e: IllegalArgumentException) {
            return false
        } catch (e: SecurityException) {
            return false
        }
        if (audio.state != AudioRecord.STATE_INITIALIZED) {
            audio.release()
            return false
        }
        try {
            audio.startRecording()
        } catch (e: IllegalStateException) {
            audio.release()
            return false
        }
        if (audio.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            audio.release()
            return false
        }
        record = audio
        running = true
        thread = Thread({ pump(audio) }, "jsti-wav-recorder").apply { start() }
        return true
    }

    private fun pump(audio: AudioRecord) {
        try {
            capture(audio)
        } catch (e: java.io.IOException) {
            failed = true
        }
        // Stopping the session releases the AudioRecord; the owner does that on this signal.
        if (failed && running) onCaptureFailed()
    }

    private fun capture(audio: AudioRecord) {
        val chunk = ShortArray(WavFormat.SAMPLE_RATE / 10)
        val bytes = ByteBuffer.allocate(chunk.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        val limit = maxSeconds.toLong() * WavFormat.BYTES_PER_SECOND
        var written = 0L
        BufferedOutputStream(FileOutputStream(file)).use { out ->
            out.write(ByteArray(WavFormat.HEADER_BYTES))
            while (running) {
                val read = audio.read(chunk, 0, chunk.size)
                if (read <= 0) {
                    if (read < 0) {
                        failed = true
                        break
                    }
                    continue
                }
                if (paused) {
                    onLevel(WavFormat.level(chunk, 0))
                    continue
                }
                if (System.nanoTime() < mutedUntil) chunk.fill(0, 0, read)
                bytes.clear()
                bytes.asShortBuffer().put(chunk, 0, read)
                out.write(bytes.array(), 0, read * 2)
                sink?.invoke(bytes.array().copyOf(read * 2))
                written += read * 2
                onLevel(WavFormat.level(chunk, read))
                if (written >= limit) {
                    running = false
                    onLimitReached()
                }
            }
        }
        RandomAccessFile(file, "rw").use { it.write(WavFormat.header(written)) }
    }

    override fun setPaused(paused: Boolean) {
        this.paused = paused
    }

    override fun mute(millis: Long) {
        // Chunks are read up to a buffer behind the microphone, so the margin covers the sound's tail.
        mutedUntil = System.nanoTime() + (millis + MUTE_MARGIN_MS) * 1_000_000
    }

    /**
     * Stops capture and returns the number of audio bytes recorded, or -1 if capture failed.
     * Idempotent and serialised, so overlapping disposals cannot release the recorder twice.
     */
    @Synchronized
    override fun stop(): Long {
        running = false
        record?.let {
            runCatching { it.stop() }
        }
        thread?.join()
        record?.release()
        record = null
        thread = null
        if (failed) return -1
        return (file.length() - WavFormat.HEADER_BYTES).coerceAtLeast(0)
    }

    private companion object {
        /** The capture buffer (a fifth of a second) plus output latency. */
        const val MUTE_MARGIN_MS = 250L
    }
}

/**
 * Recordings that outlived their session: the screen closed mid-recording, or the process died before
 * the recorder wrote its header.
 */
object RecordingRecovery {
    /** About a quarter of a second; shorter recordings cannot contain a word. */
    const val MIN_AUDIO_BYTES = WavFormat.BYTES_PER_SECOND / 4

    /**
     * Rewrites [file]'s WAV header from its length and returns the audio bytes, or -1 when it is too
     * short to hold a word or cannot be read, in which case the caller deletes it.
     */
    fun finalise(file: File): Long {
        val length = file.length()
        // Odd trailing bytes are a sample cut off mid-write.
        val audio = (length - WavFormat.HEADER_BYTES).let { it - it % 2 }
        if (audio < MIN_AUDIO_BYTES || audio > UInt.MAX_VALUE.toLong() - 36) return -1
        return try {
            RandomAccessFile(file, "rw").use {
                it.write(WavFormat.header(audio))
                it.setLength(WavFormat.HEADER_BYTES + audio)
            }
            audio
        } catch (e: java.io.IOException) {
            -1
        }
    }
}
