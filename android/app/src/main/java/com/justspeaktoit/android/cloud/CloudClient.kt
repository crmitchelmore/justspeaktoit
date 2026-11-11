package com.justspeaktoit.android.cloud

import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/**
 * Lets another thread abort a blocking request: [cancel] disconnects the connection, which makes
 * any blocked write or read fail immediately.
 */
class CallHandle {
    @Volatile private var connection: HttpURLConnection? = null

    @Volatile var cancelled = false
        private set

    internal fun attach(conn: HttpURLConnection) {
        connection = conn
        if (cancelled) conn.disconnect()
    }

    /** Set when the user let the request go (from Settings), as opposed to a timeout or teardown. */
    @Volatile var released = false
        private set

    fun cancel() {
        cancelled = true
        connection?.disconnect()
    }

    /** Cancels on the user's behalf; the blocked call then throws [RequestReleasedException]. */
    fun release() {
        released = true
        cancel()
    }
}

/** A request the user stopped; callers treat it as a cancel, not a failure. */
class RequestReleasedException(cause: Throwable? = null) : Exception("Request released", cause)

/** Blocking cloud requests; [CloudClient] in production. [call] lets another thread abort them. */
interface CloudService {
    fun transcribe(
        model: CloudModel,
        apiKey: String,
        audio: File,
        languageTag: String?,
        call: CallHandle,
        format: SharedAudio.Format = SharedAudio.Format("wav", "audio/wav"),
    ): String

    fun cleanup(model: CleanupModel, apiKey: String, transcript: String, call: CallHandle): String
}

/**
 * Blocking HTTPS client for OpenAI-compatible APIs; call from a background dispatcher. Keys are
 * only sent as bearer tokens and never logged.
 */
class CloudClient(
    private val connectTimeoutMs: Int = 15_000,
    private val readTimeoutMs: Int = 120_000,
) : CloudService {
    override fun transcribe(
        model: CloudModel,
        apiKey: String,
        audio: File,
        languageTag: String?,
        call: CallHandle,
        format: SharedAudio.Format,
    ): String {
        val multipart = CloudWire.multipart(
            fields = CloudWire.transcriptionFields(model, languageTag),
            fileField = "file",
            fileName = "dictation.${format.extension}",
            mimeType = format.mimeType,
            boundary = "jsti-" + UUID.randomUUID(),
        )
        val url = "${model.provider.baseUrl}/audio/transcriptions"
        val body = post(url, apiKey, multipart.contentType, call) { conn ->
            conn.setFixedLengthStreamingMode(multipart.contentLength(audio.length()))
            conn.outputStream.use { out ->
                out.write(multipart.head)
                audio.inputStream().use { it.copyTo(out) }
                out.write(multipart.tail)
            }
        }
        return CloudWire.transcriptText(body)
    }

    /** Sends cleanup to the model's own route: its native provider, or OpenRouter. */
    override fun cleanup(model: CleanupModel, apiKey: String, transcript: String, call: CallHandle): String {
        val json = CloudWire.cleanupBody(model.apiName, transcript, CloudWire.cleanupMaxTokens(model)).toByteArray()
        val url = CloudWire.cleanupUrl(model)
        val body = post(url, apiKey, "application/json", call) { conn ->
            conn.setFixedLengthStreamingMode(json.size)
            conn.outputStream.use { it.write(json) }
        }
        return CloudWire.cleanupText(body)
    }

    internal fun post(
        url: String,
        apiKey: String,
        contentType: String,
        call: CallHandle,
        write: (HttpURLConnection) -> Unit,
    ): String {
        val conn = URL(url).openConnection() as HttpURLConnection
        call.attach(conn)
        try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.connectTimeout = connectTimeoutMs
            conn.readTimeout = readTimeoutMs
            conn.setRequestProperty("Authorization", "Bearer $apiKey")
            conn.setRequestProperty("Content-Type", contentType)
            conn.setRequestProperty("Accept", "application/json")
            write(conn)
            val status = conn.responseCode
            if (status !in 200..299) {
                conn.errorStream?.close()
                throw CloudException(CloudWire.failureForStatus(status), "HTTP $status")
            }
            return conn.inputStream.use { CloudWire.readBody(it) }
        } catch (e: IOException) {
            if (call.released) throw RequestReleasedException(e)
            throw CloudException(CloudWire.failureForIo(e), "Network error", e)
        } finally {
            conn.disconnect()
        }
    }
}
