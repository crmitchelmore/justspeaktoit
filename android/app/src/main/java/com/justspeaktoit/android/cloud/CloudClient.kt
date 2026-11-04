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

    fun cancel() {
        cancelled = true
        connection?.disconnect()
    }
}

/**
 * Blocking HTTPS client for OpenAI-compatible APIs; call from a background dispatcher. Keys are
 * only sent as bearer tokens and never logged.
 */
class CloudClient(
    private val connectTimeoutMs: Int = 15_000,
    private val readTimeoutMs: Int = 120_000,
) {
    fun transcribe(model: CloudModel, apiKey: String, audio: File, languageTag: String?, call: CallHandle): String {
        val multipart = CloudWire.multipart(
            fields = CloudWire.transcriptionFields(model, languageTag),
            fileField = "file",
            fileName = "dictation.wav",
            mimeType = "audio/wav",
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

    fun cleanup(apiKey: String, transcript: String, call: CallHandle): String {
        val json = CloudWire.cleanupBody(CloudCatalog.CLEANUP_MODEL, transcript).toByteArray()
        val url = "${CloudProvider.OpenRouter.baseUrl}/chat/completions"
        val body = post(url, apiKey, "application/json", call) { conn ->
            conn.setFixedLengthStreamingMode(json.size)
            conn.outputStream.use { it.write(json) }
        }
        return CloudWire.cleanupText(body)
    }

    private fun post(
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
            return conn.inputStream.bufferedReader().use { it.readText() }
        } catch (e: IOException) {
            throw CloudException(CloudWire.failureForIo(e), "Network error", e)
        } finally {
            conn.disconnect()
        }
    }
}
