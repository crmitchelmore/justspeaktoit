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

/**
 * Captures microphone audio to a WAV file on a dedicated thread. Capture stops automatically at
 * [maxSeconds] so an upload stays within provider size limits.
 */
class WavRecorder(
    private val file: File,
    private val onLevel: (Float) -> Unit,
    private val onLimitReached: () -> Unit,
    private val maxSeconds: Int = 600,
) {
    @Volatile private var running = false

    @Volatile private var failed = false
    private var thread: Thread? = null
    private var record: AudioRecord? = null

    /** Returns false when the microphone cannot be opened. Requires RECORD_AUDIO. */
    @SuppressLint("MissingPermission")
    fun start(): Boolean {
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
                bytes.clear()
                bytes.asShortBuffer().put(chunk, 0, read)
                out.write(bytes.array(), 0, read * 2)
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

    /** Stops capture and returns the number of audio bytes recorded, or -1 if capture failed. */
    fun stop(): Long {
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
}
