package com.justspeaktoit.android.telemetry

import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Sends events to PostHog EU Cloud, the endpoint the Mac app uses, with the same envelope. Events are held in
 * memory only, one request at a time, and dropped on failure rather than retried: nothing is written to disk,
 * so an opt-out ([purge]) leaves nothing behind. [purge] also cancels the request in flight, which checks for
 * that again just before it sends. A blank [projectKey] (any build without the release secret) never opens a
 * connection.
 */
class PostHogTransport(
    private val projectKey: String,
    private val executor: Executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "jsti-analytics").apply { isDaemon = true }
    },
    private val post: (String, PostCancellation) -> Unit = ::postToPostHog,
) : AnalyticsTransport {
    // Bumped by purge; a queued send from an older generation is dropped before it reaches the network.
    private val generation = AtomicInteger()

    @Volatile private var inFlight: PostCancellation? = null

    val isConfigured: Boolean get() = projectKey.isNotBlank()

    override fun send(payload: AnalyticsPayload) {
        if (!isConfigured) return
        val sentIn = generation.get()
        val body = PostHogEnvelope.json(payload, projectKey)
        executor.execute {
            if (generation.get() != sentIn) return@execute
            val call = PostCancellation()
            inFlight = call
            // A purge between the first check and publishing the call would not have seen it.
            if (generation.get() != sentIn) call.cancel()
            try {
                if (!call.isCancelled) post(body, call)
            } finally {
                inFlight = null
            }
        }
    }

    override fun purge() {
        generation.incrementAndGet()
        inFlight?.cancel()
    }

    companion object {
        const val ENDPOINT = "https://eu.i.posthog.com/capture/"
        private const val TIMEOUT_MS = 10_000

        private fun postToPostHog(body: String, call: PostCancellation) {
            val connection = URI.create(ENDPOINT).toURL().openConnection() as HttpURLConnection
            if (!call.onCancel(connection::disconnect)) return
            try {
                connection.requestMethod = "POST"
                connection.connectTimeout = TIMEOUT_MS
                connection.readTimeout = TIMEOUT_MS
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                val bytes = body.toByteArray(Charsets.UTF_8)
                connection.outputStream.use { stream ->
                    if (call.isCancelled) return
                    stream.write(bytes)
                }
                connection.responseCode
            } catch (_: IOException) {
                // Dropped (or cancelled by an opt-out): analytics never retries or persists.
            } finally {
                connection.disconnect()
            }
        }
    }
}

/** Lets [PostHogTransport.purge] stop a request that is already running. */
class PostCancellation {
    private var action: (() -> Unit)? = null

    @Volatile var isCancelled = false
        private set

    /** Runs [cancel] when cancelled; returns false, without registering it, if that has already happened. */
    @Synchronized
    fun onCancel(cancel: () -> Unit): Boolean {
        if (isCancelled) return false
        action = cancel
        return true
    }

    @Synchronized
    fun cancel() {
        if (isCancelled) return
        isCancelled = true
        action?.invoke()
        action = null
    }
}

/** The PostHog capture body, identical in shape to the Mac's `PostHogProductAnalyticsSink.eventEnvelope`. */
object PostHogEnvelope {
    fun json(payload: AnalyticsPayload, projectKey: String): String {
        val properties = JSONObject()
        payload.properties.forEach { (key, value) -> properties.put(key, value) }
        // Discarding the IP alone still permits server-side enrichment, so turn GeoIP off as well.
        properties.put("\$geoip_disable", true)
        properties.put("distinct_id", payload.distinctId)
        properties.put("\$lib", "just-speak-to-it")
        properties.put("\$lib_version", "1")
        properties.put("timestamp", DateTimeFormatter.ISO_INSTANT.format(payload.timestamp))
        return JSONObject()
            .put("api_key", projectKey)
            .put("event", payload.event)
            .put("properties", properties)
            .toString()
    }
}
