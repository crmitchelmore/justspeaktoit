package com.justspeaktoit.android.cloud.live

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Runs one live session's work on a single thread, so session state needs no locks. Tests replace it
 * with a virtual clock.
 */
interface LiveScheduler {
    fun execute(task: () -> Unit)

    fun schedule(delayMs: Long, task: () -> Unit): Cancellable

    fun shutdown()

    fun interface Cancellable {
        fun cancel()
    }
}

/** One daemon thread per session; work posted after [shutdown] is dropped. */
class ExecutorLiveScheduler : LiveScheduler {
    private val executor = ScheduledThreadPoolExecutor(1) { runnable ->
        Thread(runnable, "live-transcription").apply { isDaemon = true }
    }.apply { executeExistingDelayedTasksAfterShutdownPolicy = false }

    override fun execute(task: () -> Unit) {
        try {
            executor.execute { task() }
        } catch (_: RejectedExecutionException) {
            // The session has ended.
        }
    }

    override fun schedule(delayMs: Long, task: () -> Unit): LiveScheduler.Cancellable = try {
        val future = executor.schedule({ task() }, delayMs, TimeUnit.MILLISECONDS)
        LiveScheduler.Cancellable { future.cancel(false) }
    } catch (_: RejectedExecutionException) {
        LiveScheduler.Cancellable {}
    }

    override fun shutdown() = executor.shutdown()
}

data class LiveRequest(val url: String, val headers: Map<String, String>) {
    /** Credentials stay out of logs and test failure messages. */
    override fun toString(): String = "LiveRequest(${url.replace(Regex("token=[^&]*"), "token=***")})"
}

/** The sending half of a WebSocket. Sends are queued in order; false means the socket is gone or full. */
interface LiveSocket {
    fun send(text: String): Boolean

    fun send(bytes: ByteArray): Boolean

    /** Bytes accepted by [send] that have not left the device yet. */
    val queuedBytes: Long

    fun close(code: Int, reason: String)

    fun cancel()
}

/** Socket events, delivered on any thread. */
interface LiveSocketListener {
    fun onOpen()

    fun onText(text: String)

    fun onClosed(code: Int, reason: String)

    /** [httpStatus] is set when the handshake was refused. */
    fun onFailure(error: Throwable, httpStatus: Int?)
}

fun interface LiveSocketFactory {
    fun open(request: LiveRequest, listener: LiveSocketListener): LiveSocket
}

/** The production transport. */
class OkHttpLiveSocketFactory(private val client: OkHttpClient = sharedClient) : LiveSocketFactory {
    override fun open(request: LiveRequest, listener: LiveSocketListener): LiveSocket {
        val builder = Request.Builder().url(request.url)
        request.headers.forEach { (name, value) -> builder.header(name, value) }
        val socket = client.newWebSocket(
            builder.build(),
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = listener.onOpen()

                override fun onMessage(webSocket: WebSocket, text: String) = listener.onText(text)

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) = listener.onText(bytes.utf8())

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(NORMAL_CLOSURE, null)
                    listener.onClosed(code, reason)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) =
                    listener.onClosed(code, reason)

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                    listener.onFailure(t, response?.code)
            },
        )
        return object : LiveSocket {
            override fun send(text: String): Boolean = socket.send(text)

            override fun send(bytes: ByteArray): Boolean = socket.send(bytes.toByteString())

            override val queuedBytes: Long get() = socket.queueSize()

            override fun close(code: Int, reason: String) {
                socket.close(code, reason)
            }

            override fun cancel() = socket.cancel()
        }
    }

    companion object {
        const val NORMAL_CLOSURE = 1000

        val sharedClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.MILLISECONDS)
                .pingInterval(15, TimeUnit.SECONDS)
                .build()
        }
    }
}
