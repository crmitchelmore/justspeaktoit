package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.Locale

/** Request and response formats for OpenAI-compatible endpoints. Pure, so it is unit-tested. */
object CloudWire {
    /** Form fields for `/audio/transcriptions`. Language is sent as an ISO 639-1 code. */
    fun transcriptionFields(model: CloudModel, languageTag: String?): List<Pair<String, String>> {
        val fields = mutableListOf("model" to model.apiName, "response_format" to "json")
        val language = languageTag?.let { Locale.forLanguageTag(it).language }?.takeIf { it.isNotEmpty() }
        if (language != null) fields += model.languageField to language
        return fields
    }

    class Multipart(val boundary: String, val head: ByteArray, val tail: ByteArray) {
        val contentType: String get() = "multipart/form-data; boundary=$boundary"

        fun contentLength(fileBytes: Long): Long = head.size + fileBytes + tail.size
    }

    /** Builds everything around the file part so the audio itself can be streamed from disk. */
    fun multipart(
        fields: List<Pair<String, String>>,
        fileField: String,
        fileName: String,
        mimeType: String,
        boundary: String,
    ): Multipart {
        val head = buildString {
            for ((name, value) in fields) {
                append("--").append(boundary).append("\r\n")
                append("Content-Disposition: form-data; name=\"").append(name).append("\"\r\n\r\n")
                append(value).append("\r\n")
            }
            append("--").append(boundary).append("\r\n")
            append("Content-Disposition: form-data; name=\"").append(fileField)
                .append("\"; filename=\"").append(fileName).append("\"\r\n")
            append("Content-Type: ").append(mimeType).append("\r\n\r\n")
        }
        val tail = "\r\n--$boundary--\r\n"
        return Multipart(boundary, head.toByteArray(), tail.toByteArray())
    }

    fun cleanupBody(model: String, transcript: String): String = JSONObject()
        .put("model", model)
        .put(
            "messages",
            JSONArray()
                .put(JSONObject().put("role", "system").put("content", CleanupPolicy.systemPrompt()))
                .put(JSONObject().put("role", "user").put("content", CleanupPolicy.userMessage(transcript))),
        )
        .toString()

    /** @throws CloudException when the body is not the expected JSON. */
    fun transcriptText(body: String): String = parse { JSONObject(body).getString("text") }

    fun cleanupText(body: String): String = parse {
        JSONObject(body).getJSONArray("choices").getJSONObject(0).getJSONObject("message").getString("content")
    }

    private inline fun parse(block: () -> String): String = try {
        block().trim()
    } catch (e: JSONException) {
        throw CloudException(DictationFailure.Server, "Unexpected response", e)
    }

    fun failureForStatus(status: Int): DictationFailure = when (status) {
        401, 403 -> DictationFailure.InvalidKey
        408 -> DictationFailure.NetworkTimeout
        429 -> DictationFailure.TooManyRequests
        in 400..499 -> DictationFailure.Client
        else -> DictationFailure.Server
    }

    fun failureForIo(error: IOException): DictationFailure =
        if (error is SocketTimeoutException) DictationFailure.NetworkTimeout else DictationFailure.Network
}

class CloudException(val failure: DictationFailure, message: String, cause: Throwable? = null) :
    Exception(message, cause)
