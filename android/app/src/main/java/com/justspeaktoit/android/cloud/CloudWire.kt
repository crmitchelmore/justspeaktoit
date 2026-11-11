package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
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

    fun cleanupUrl(model: CleanupModel): String = "${model.provider.baseUrl}/chat/completions"

    /** Anthropic rejects requests without an output limit; other routes keep their default. */
    const val ANTHROPIC_MAX_TOKENS = 8_192

    fun cleanupMaxTokens(model: CleanupModel): Int? =
        if (model.provider == CloudProvider.Anthropic) ANTHROPIC_MAX_TOKENS else null

    fun cleanupBody(model: String, transcript: String, maxTokens: Int? = null): String = JSONObject()
        .put("model", model)
        .apply { if (maxTokens != null) put("max_tokens", maxTokens) }
        .put(
            "messages",
            JSONArray()
                .put(JSONObject().put("role", "system").put("content", CleanupPolicy.systemPrompt()))
                .put(JSONObject().put("role", "user").put("content", CleanupPolicy.userMessage(transcript))),
        )
        .toString()

    /** @throws CloudException when the body is not the expected JSON. */
    fun transcriptText(body: String): String = parse { JSONObject(body).requireString("text") }

    /** Rejects output the model did not finish (for example `finish_reason: "length"`). */
    fun cleanupText(body: String): String = parse {
        val choice = JSONObject(body).getJSONArray("choices").getJSONObject(0)
        val finish = choice.opt("finish_reason")
        if (finish is String && finish != "stop") {
            throw CloudException(DictationFailure.Server, "Cleanup did not finish: $finish")
        }
        choice.getJSONObject("message").requireString("content")
    }

    // Android's getString() coerces null, numbers and objects to text; only a real string is a transcript.
    private fun JSONObject.requireString(name: String): String =
        opt(name) as? String ?: throw CloudException(DictationFailure.Server, "Missing $name")

    private inline fun parse(block: () -> String): String = try {
        block().trim()
    } catch (e: JSONException) {
        throw CloudException(DictationFailure.Server, "Unexpected response", e)
    }

    /** Transcripts and cleanups are small; a larger body is not a response this app asked for. */
    const val MAX_RESPONSE_BYTES = 1024 * 1024

    /**
     * Reads a UTF-8 response body of at most [limit] bytes, so a misbehaving or hostile endpoint
     * cannot exhaust memory. @throws CloudException when the body is larger.
     */
    fun readBody(input: InputStream, limit: Int = MAX_RESPONSE_BYTES): String {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            if (out.size() + read > limit) {
                throw CloudException(DictationFailure.Server, "Response larger than $limit bytes")
            }
            out.write(buffer, 0, read)
        }
        return out.toString(Charsets.UTF_8.name())
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
