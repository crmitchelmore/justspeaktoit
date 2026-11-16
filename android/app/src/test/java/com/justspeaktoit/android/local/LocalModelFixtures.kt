package com.justspeaktoit.android.local

import java.io.ByteArrayInputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList

/** A small pinned model whose bytes and SHA-256 are known, so downloads can be verified end to end. */
internal fun pinnedModel(
    id: String = "local/whisperkit/tiny",
    content: ByteArray = ByteArray(1_000) { (it % 251).toByte() },
    minimumDeviceMemoryBytes: Long? = null,
) = WhisperModel(
    catalogId = id,
    displayName = "Whisper ${id.substringAfterLast('/')}",
    summary = "Test model",
    quantization = "f16",
    multilingual = true,
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/abc/ggml-${id.substringAfterLast('/')}.bin",
    filename = "ggml-${id.substringAfterLast('/')}.bin",
    bytes = content.size.toLong(),
    sha256 = MessageDigest.getInstance("SHA-256").digest(content).joinToString("") { "%02x".format(it) },
    license = "MIT",
    allowedHosts = listOf(".hf.co", ".huggingface.co", "huggingface.co"),
    minimumDeviceMemoryBytes = minimumDeviceMemoryBytes,
)

/** Serves model bytes as an HTTP server would, recording each request's URL and range offset. */
internal class FakeModelSource(private val content: ByteArray) : ModelSource {
    data class Request(val url: String, val offset: Long)

    val requests = CopyOnWriteArrayList<Request>()

    /** Overrides the response for a request; the default honours the range with a 200 or 206. */
    @Volatile var respond: (Request) -> ModelResponse = ::serve

    override fun open(url: String, offset: Long): ModelResponse {
        val request = Request(url, offset)
        requests += request
        return respond(request)
    }

    fun serve(request: Request): ModelResponse = if (request.offset > 0) {
        ModelResponse(206, null, ByteArrayInputStream(content, request.offset.toInt(), content.size))
    } else {
        ModelResponse(200, null, ByteArrayInputStream(content))
    }

    companion object {
        fun failing(): ModelSource = ModelSource { _, _ -> throw IOException("offline") }
    }
}
