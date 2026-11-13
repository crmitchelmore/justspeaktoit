package com.justspeaktoit.android.cloud.live

import com.justspeaktoit.android.cloud.CloudWire
import com.justspeaktoit.android.dictation.DictationFailure

/** How a live session ended. A failure keeps the text received so far so nothing heard is lost. */
sealed interface LiveOutcome {
    data class Completed(val text: String) : LiveOutcome

    data class Failed(val failure: DictationFailure, val recoveredText: String) : LiveOutcome
}

/** Session events, delivered on the session's thread. */
interface LiveTranscriptListener {
    /** The whole session's text so far. Each call replaces the previous one. */
    fun onPartial(text: String)

    /** Called exactly once, unless the session was cancelled. */
    fun onEnd(outcome: LiveOutcome)
}

/** A streaming transcription: audio goes in while recording, text comes back as it is recognised. */
interface LiveTranscriber {
    /** Opens the connection. Audio appended before then is held, up to five seconds of it. */
    fun connect(apiKey: String)

    /** 16 kHz mono PCM16 little-endian, as the recorder captures it. */
    fun append(pcm: ByteArray)

    /** Sends the rest of the audio, asks the provider to finalise, and ends within a bounded time. */
    fun finish()

    /** Ends at once without an outcome. */
    fun cancel()
}

/**
 * The lifecycle every live provider shares, ported from SpeakCore's streaming clients:
 * - audio waits until the provider says it is ready, keeping only the newest five seconds;
 * - after that, more than five seconds stuck in the socket is a stall, never silently dropped audio;
 * - each connection attempt has an identity, so callbacks from a superseded or ended one are ignored;
 * - a finish drains admitted audio, sends the provider's end signal and ends within a deadline;
 * - a failure ends the session with the text received so far; nothing switches provider silently.
 *
 * All state is confined to [scheduler]'s thread.
 */
abstract class LiveSession(
    private val scheduler: LiveScheduler,
    private val sockets: LiveSocketFactory,
    private val listener: LiveTranscriptListener,
    /** The provider's PCM rate; [encode] produces audio at this rate. */
    sampleRate: Int,
) : LiveTranscriber {
    private val maxBufferedBytes = sampleRate.toLong() * BYTES_PER_SAMPLE * BUFFER_SECONDS
    private var apiKey: String? = null
    private var socket: LiveSocket? = null
    private var attempt = 0
    private val pending = ArrayDeque<ByteArray>()
    private var pendingBytes = 0L
    private var hasAudio = false
    private var finishStarted = false
    private var lastPartial = ""
    private val timers = mutableListOf<LiveScheduler.Cancellable>()

    /** The current attempt's socket, once opened. */
    protected val currentSocket: LiveSocket? get() = socket

    protected var ready = false
        private set
    protected var done = false
        private set
    protected var finishRequested = false
        private set

    /** Set once the provider's last control message is queued: a close after it is a normal end. */
    protected var endSignalSent = false

    protected open val readyDeadlineMs: Long = 10_000
    protected open val finishDeadlineMs: Long = 8_000

    protected abstract fun request(apiKey: String): LiveRequest

    /** Converts recorder PCM into the provider's frames. */
    protected abstract fun encode(pcm: ByteArray): List<ByteArray>

    /** Audio the encoder still holds when recording stops. */
    protected open fun encodeTail(): List<ByteArray> = emptyList()

    protected abstract fun sendAudio(socket: LiveSocket, frame: ByteArray): Boolean

    protected open fun onSocketOpen(socket: LiveSocket) = Unit

    protected abstract fun onMessage(text: String)

    /** Called once, after a requested finish has drained the admitted audio. */
    protected abstract fun startFinish(socket: LiveSocket)

    /** The best text so far, shown while recording and kept on failure. */
    protected abstract fun transcript(): String

    /** The text a finish returns. */
    protected open fun finalTranscript(): String = transcript()

    /** Whether a failure before readiness should try another connection instead of ending. */
    protected open fun retryBeforeReady(): Boolean = false

    override fun connect(apiKey: String) = scheduler.execute {
        if (done || this.apiKey != null) return@execute
        this.apiKey = apiKey
        open()
    }

    override fun append(pcm: ByteArray) = scheduler.execute {
        if (done || finishRequested || pcm.isEmpty()) return@execute
        hasAudio = true
        admit(encode(pcm))
    }

    override fun finish() = scheduler.execute {
        if (done || finishRequested) return@execute
        finishRequested = true
        admit(encodeTail())
        if (!hasAudio) {
            // Nothing was recorded, so there is nothing to finalise.
            complete()
            return@execute
        }
        after(finishDeadlineMs) {
            if (endSignalSent && (socket?.queuedBytes ?: 0L) == 0L) complete() else fail(DictationFailure.NetworkTimeout)
        }
        if (ready) beginFinish()
    }

    override fun cancel() = scheduler.execute {
        if (done) return@execute
        end()
    }

    /** The provider accepted the session: queued audio flows, and a waiting finish begins. */
    protected fun markReady() {
        if (ready || done) return
        ready = true
        flush()
        if (finishRequested && !done) beginFinish()
    }

    /** Publishes the current text when it changed. */
    protected fun publish() {
        val text = transcript()
        if (text == lastPartial) return
        lastPartial = text
        listener.onPartial(text)
    }

    protected fun after(delayMs: Long, task: () -> Unit) {
        val id = attempt
        timers += scheduler.schedule(delayMs) {
            scheduler.execute { if (!done && id == attempt) task() }
        }
    }

    protected fun complete() {
        if (done) return
        val text = finalTranscript().trim()
        end(close = true)
        listener.onEnd(LiveOutcome.Completed(text))
    }

    /** Ends normally once everything sent has left the device; until then the finish deadline decides. */
    protected fun completeIfDrained() {
        if ((socket?.queuedBytes ?: 0L) == 0L) complete()
    }

    protected fun fail(failure: DictationFailure) {
        if (done) return
        val text = transcript().trim()
        end()
        listener.onEnd(LiveOutcome.Failed(failure, text))
    }

    private fun end(close: Boolean = false) {
        done = true
        timers.forEach { it.cancel() }
        timers.clear()
        pending.clear()
        socket?.let { if (close) it.close(NORMAL_CLOSURE, "") else it.cancel() }
        socket = null
        scheduler.shutdown()
    }

    private fun open() {
        attempt += 1
        val id = attempt
        ready = false
        socket = sockets.open(request(checkNotNull(apiKey)), AttemptListener(id))
        after(readyDeadlineMs) { if (!ready) transportEnded(DictationFailure.NetworkTimeout) }
    }

    private fun beginFinish() {
        if (finishStarted) return
        finishStarted = true
        flush()
        socket?.let { if (!done) startFinish(it) }
    }

    private fun admit(frames: List<ByteArray>) {
        for (frame in frames) {
            if (frame.isEmpty()) continue
            pending.addLast(frame)
            pendingBytes += frame.size
        }
        if (!ready) {
            while (pendingBytes > maxBufferedBytes && pending.size > 1) {
                pendingBytes -= pending.removeFirst().size
            }
            return
        }
        flush()
    }

    private fun flush() {
        val socket = socket ?: return
        if (!ready) return
        while (pending.isNotEmpty()) {
            val frame = pending.removeFirst()
            pendingBytes -= frame.size
            if (!sendAudio(socket, frame)) {
                fail(DictationFailure.Network)
                return
            }
        }
        // The socket queue holds encoded frames; JSON and base64 framing roughly doubles PCM at worst.
        if (socket.queuedBytes > maxBufferedBytes * 2) fail(DictationFailure.NetworkTimeout)
    }

    /** The connection ended or the provider reported a fatal error. */
    protected fun transportEnded(failure: DictationFailure) {
        if (endSignalSent) {
            complete()
            return
        }
        if (!ready && !finishRequested && retryBeforeReady()) {
            socket?.cancel()
            open()
            return
        }
        fail(failure)
    }

    private inner class AttemptListener(private val id: Int) : LiveSocketListener {
        private fun onCurrent(task: () -> Unit) = scheduler.execute { if (!done && id == attempt) task() }

        override fun onOpen() = onCurrent { socket?.let(::onSocketOpen) }

        override fun onText(text: String) = onCurrent { onMessage(text) }

        override fun onClosed(code: Int, reason: String) = onCurrent { transportEnded(DictationFailure.Network) }

        override fun onFailure(error: Throwable, httpStatus: Int?) = onCurrent {
            transportEnded(httpStatus?.let(CloudWire::failureForStatus) ?: DictationFailure.Network)
        }
    }

    companion object {
        const val BYTES_PER_SAMPLE = 2
        const val BUFFER_SECONDS = 5
        const val NORMAL_CLOSURE = 1000
    }
}
