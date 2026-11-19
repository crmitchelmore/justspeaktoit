package com.justspeaktoit.android.cloud.live

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudModel
import java.io.IOException

/** Runs posted work at once on the test thread, and timers only when the virtual clock is advanced. */
internal class ManualScheduler : LiveScheduler {
    private class Timer(val at: Long, val seq: Long, val task: () -> Unit) {
        var cancelled = false
    }

    var now = 0L
        private set
    var isShutdown = false
        private set
    private val queue = ArrayDeque<() -> Unit>()
    private val timers = mutableListOf<Timer>()
    private var draining = false
    private var seq = 0L

    override fun execute(task: () -> Unit) {
        if (isShutdown) return
        queue.addLast(task)
        drain()
    }

    override fun schedule(delayMs: Long, task: () -> Unit): LiveScheduler.Cancellable {
        if (isShutdown) return LiveScheduler.Cancellable {}
        val timer = Timer(now + delayMs, seq++, task)
        timers += timer
        return LiveScheduler.Cancellable { timer.cancelled = true }
    }

    override fun shutdown() {
        isShutdown = true
        timers.clear()
    }

    fun advanceBy(ms: Long) {
        val target = now + ms
        while (true) {
            val next = timers.filter { !it.cancelled && it.at <= target }.minWithOrNull(compareBy({ it.at }, { it.seq }))
                ?: break
            timers.remove(next)
            now = next.at
            next.task()
            drain()
        }
        now = target
    }

    private fun drain() {
        if (draining) return
        draining = true
        try {
            while (queue.isNotEmpty()) queue.removeFirst()()
        } finally {
            draining = false
        }
    }
}

/** A socket whose server side the test plays. Everything sent is kept in order. */
internal class FakeSocket(val request: LiveRequest, private val listener: LiveSocketListener) : LiveSocket {
    val sent = mutableListOf<Any>()
    val texts: List<String> get() = sent.filterIsInstance<String>()
    val binaries: List<ByteArray> get() = sent.filterIsInstance<ByteArray>()
    var accepts = true
    override var queuedBytes = 0L
    var closedWith: Int? = null
    var cancelled = false

    override fun send(text: String): Boolean = accepts.also { if (it) sent += text }

    override fun send(bytes: ByteArray): Boolean = accepts.also { if (it) sent += bytes }

    override fun close(code: Int, reason: String) {
        closedWith = code
    }

    override fun cancel() {
        cancelled = true
    }

    fun serverOpen() = listener.onOpen()

    fun serverSends(json: String) = listener.onText(json)

    fun serverCloses(code: Int = 1000) = listener.onClosed(code, "")

    fun serverFails(httpStatus: Int? = null) = listener.onFailure(IOException("test"), httpStatus)
}

internal class FakeSockets : LiveSocketFactory {
    val opened = mutableListOf<FakeSocket>()
    val last: FakeSocket get() = opened.last()

    override fun open(request: LiveRequest, listener: LiveSocketListener): LiveSocket =
        FakeSocket(request, listener).also { opened += it }
}

internal class RecordingListener : LiveTranscriptListener {
    val partials = mutableListOf<String>()
    val outcomes = mutableListOf<LiveOutcome>()
    val outcome: LiveOutcome? get() = outcomes.singleOrNull()

    override fun onPartial(text: String) {
        partials += text
    }

    override fun onEnd(outcome: LiveOutcome) {
        outcomes += outcome
    }
}

internal fun liveModel(catalogId: String): CloudModel =
    CloudCatalog.liveTranscriptionModels.single { it.catalogId == catalogId }

/** [millis] of 16 kHz PCM16 at a constant level. */
internal fun pcm(millis: Int, level: Short = 1000): ByteArray {
    val samples = 16_000 * millis / 1000
    return ByteArray(samples * 2).also { bytes ->
        for (i in 0 until samples) {
            bytes[i * 2] = level.toByte()
            bytes[i * 2 + 1] = (level.toInt() shr 8).toByte()
        }
    }
}
