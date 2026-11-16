package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.AudioRecorder
import com.justspeaktoit.android.cloud.CaptureLevel
import com.justspeaktoit.android.cloud.WavFormat
import com.justspeaktoit.android.resources.SystemResourceKind
import com.justspeaktoit.android.resources.SystemResourceRegistry
import com.justspeaktoit.android.resources.SystemResourceToken
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** What hands-free is doing, as the dictation screen shows it. */
enum class HandsFreeStatus {
    Off,

    /** The microphone is open and only its level is checked; nothing is recorded or sent. */
    Listening,

    /** Speech started a Cloud recording, which ends after the silence duration. */
    Recording,

    /** Hands-free turned itself off: the microphone failed, or a hands-free session did not finish. */
    Stopped,
}

/**
 * The microphone hands-free listens on: 16 kHz mono PCM ([WavFormat]) in chunks, on its own thread.
 * `AudioRecordMicrophone` in production.
 */
internal interface HandsFreeMicrophone {
    /** Opens the microphone; [onAudio] and [onFailed] run on the capture thread. False if it cannot open. */
    fun start(onAudio: (ShortArray, Int) -> Unit, onFailed: () -> Unit): Boolean

    /** Releases the microphone. Idempotent and does not block. */
    fun stop()
}

/** For tests and previews that never arm hands-free: the microphone never opens. */
internal object NoHandsFreeMicrophone : HandsFreeMicrophone {
    override fun start(onAudio: (ShortArray, Int) -> Unit, onFailed: () -> Unit): Boolean = false

    override fun stop() = Unit
}

/**
 * A Cloud recording fed by [gate] instead of its own microphone: the pre-roll first, then live audio,
 * written as a [WavFormat] file like `WavRecorder`'s. Hands-free plays no cues, so [mute] does nothing.
 */
internal class HandsFreeUtteranceRecorder(
    private val file: File,
    private val gate: HandsFreeGate,
    private val onLevel: (CaptureLevel) -> Unit,
    private val onLimitReached: () -> Unit,
    private val onCaptureFailed: () -> Unit,
    private val maxSeconds: Int = 600,
) : AudioRecorder, HandsFreeSink {
    // Written under the gate's lock only; read by stop() once detach() has returned.
    private var out: OutputStream? = null
    private var written = 0L
    private var full = false

    @Volatile private var failed = false

    @Volatile private var paused = false
    private var result: Long? = null
    private val bytes = ByteBuffer.allocate(WavFormat.SAMPLE_RATE * 2).order(ByteOrder.LITTLE_ENDIAN)

    override fun start(): Boolean {
        out = try {
            BufferedOutputStream(FileOutputStream(file)).apply { write(ByteArray(WavFormat.HEADER_BYTES)) }
        } catch (e: IOException) {
            return false
        }
        if (gate.attach(this)) return true
        closeQuietly()
        file.delete()
        return false
    }

    override fun write(samples: ShortArray, count: Int) {
        val stream = out ?: return
        if (failed || full) return
        if (paused) {
            onLevel(CaptureLevel(WavFormat.level(samples, 0), Double.NaN, seconds()))
            return
        }
        val length = minOf(count, samples.size, bytes.capacity() / 2)
        bytes.clear()
        bytes.asShortBuffer().put(samples, 0, length)
        try {
            stream.write(bytes.array(), 0, length * 2)
        } catch (e: IOException) {
            failed = true
            onCaptureFailed()
            return
        }
        written += length * 2L
        onLevel(CaptureLevel(WavFormat.level(samples, length), WavFormat.normalizedLevel(samples, length), seconds()))
        if (written >= maxSeconds.toLong() * WavFormat.BYTES_PER_SECOND) {
            full = true
            onLimitReached()
        }
    }

    private fun seconds(): Double = written.toDouble() / WavFormat.BYTES_PER_SECOND

    override fun setPaused(paused: Boolean) {
        this.paused = paused
    }

    @Synchronized
    override fun stop(): Long {
        result?.let { return it }
        gate.detach(this)
        val ok = try {
            out?.close()
            out = null
            RandomAccessFile(file, "rw").use { it.write(WavFormat.header(written)) }
            !failed
        } catch (e: IOException) {
            false
        }
        return (if (ok) written else -1L).also { result = it }
    }

    private fun closeQuietly() {
        try {
            out?.close()
        } catch (e: IOException) {
            // Nothing was recorded, so the file is deleted anyway.
        }
        out = null
    }
}

/**
 * Hands-free dictation for Cloud recordings (#1632), driven from the main thread of [scope].
 *
 * [arm] opens [microphone] and feeds a [HandsFreeGate]; when it hears speech, [onSpeech] starts a Cloud
 * session whose recorder ([recorder]) takes the pre-roll and live audio from the gate. The session
 * ends through the normal silence auto-stop and stop path; then [resumeListening] waits for the next
 * utterance, until [disarm]. The microphone is held in [resources] only while armed.
 */
internal class HandsFreeDictation(
    private val microphone: HandsFreeMicrophone,
    private val resources: SystemResourceRegistry,
    private val scope: CoroutineScope,
    private val onSpeech: () -> Unit,
    private val onChanged: (HandsFreeStatus) -> Unit,
) {
    var status: HandsFreeStatus = HandsFreeStatus.Off
        private set

    private var gate: HandsFreeGate? = null
    private var hold: SystemResourceToken? = null

    val armed: Boolean get() = gate != null

    /** True between speech starting and its recording attaching. */
    val startingUtterance: Boolean get() = gate?.phase == HandsFreeGate.Phase.Starting

    /** True while a recording takes the gate's audio. */
    val recordingUtterance: Boolean get() = gate?.phase == HandsFreeGate.Phase.Recording

    /** Opens the microphone and listens. Returns false, leaving hands-free stopped, if it cannot open. */
    fun arm(): Boolean {
        if (armed) return true
        val listening = HandsFreeGate()
        val opened = microphone.start(
            onAudio = { samples, count ->
                when (listening.receive(samples, count)) {
                    HandsFreeGate.Event.SpeechStarted -> scope.launch { if (gate === listening) onSpeech() }
                    HandsFreeGate.Event.Overflow -> scope.launch { if (gate === listening) disarm(failed = true) }
                    null -> Unit
                }
            },
            onFailed = { scope.launch { if (gate === listening) disarm(failed = true) } },
        )
        if (!opened) {
            change(HandsFreeStatus.Stopped)
            return false
        }
        gate = listening
        listening.resumeListening()
        hold = resources.acquire(
            kind = SystemResourceKind.Microphone,
            title = "Hands-free listening",
            reason = "Listening for speech to start a Cloud recording; nothing is recorded until you speak",
            // Its own owner, so its release control's automation ID differs from the recording's.
            owner = "HandsFreeDictation",
            releaseTitle = "Turn off hands-free",
            release = { disarm() },
        )
        change(HandsFreeStatus.Listening)
        return true
    }

    /** A recorder for the utterance speech just started, or null when none is starting. */
    fun recorder(
        file: File,
        onLevel: (CaptureLevel) -> Unit,
        onLimitReached: () -> Unit,
        onCaptureFailed: () -> Unit,
    ): AudioRecorder? {
        val listening = gate?.takeIf { it.phase == HandsFreeGate.Phase.Starting } ?: return null
        return HandsFreeUtteranceRecorder(file, listening, onLevel, onLimitReached, onCaptureFailed)
    }

    /** The triggered recording is under way. */
    fun utteranceStarted() {
        if (recordingUtterance) change(HandsFreeStatus.Recording)
    }

    /** The utterance's session has finished: listen for the next one. */
    fun resumeListening() {
        val listening = gate ?: return
        listening.resumeListening()
        change(HandsFreeStatus.Listening)
    }

    /** Closes the microphone. [failed] shows that hands-free stopped by itself. */
    fun disarm(failed: Boolean = false) {
        val listening = gate
        gate = null
        listening?.close()
        if (listening != null) microphone.stop()
        hold?.end()
        hold = null
        change(if (failed) HandsFreeStatus.Stopped else HandsFreeStatus.Off)
    }

    private fun change(next: HandsFreeStatus) {
        if (status == next) return
        status = next
        onChanged(next)
    }
}
