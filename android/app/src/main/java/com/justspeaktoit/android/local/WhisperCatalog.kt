package com.justspeaktoit.android.local

import org.json.JSONObject
import java.net.URI
import java.util.Locale

/**
 * A downloadable whisper.cpp model, from SpeakCore's `WhisperCppModels` pins. [catalogId] is the shared
 * `local/whisperkit/...` identifier every platform stores, so a choice survives a configuration
 * transfer. [minimumDeviceMemoryBytes] is set when the model is offered only on phones with at least
 * that much memory.
 */
data class WhisperModel(
    val catalogId: String,
    val displayName: String,
    val summary: String,
    val quantization: String,
    val multilingual: Boolean,
    val url: String,
    val filename: String,
    val bytes: Long,
    val sha256: String,
    val license: String,
    val allowedHosts: List<String>,
    val minimumDeviceMemoryBytes: Long?,
) {
    /** As `LocalModelDownloadRequest.allows(host:)`: an exact host, or a subdomain of a `.suffix` entry. */
    fun allowsHost(host: String): Boolean {
        val lower = host.lowercase(Locale.ROOT)
        if (lower.isEmpty()) return false
        return allowedHosts.any { allowed ->
            if (allowed.startsWith(".")) lower.endsWith(allowed) else lower == allowed
        }
    }

    fun fitsDevice(totalMemoryBytes: Long): Boolean =
        minimumDeviceMemoryBytes == null || totalMemoryBytes >= minimumDeviceMemoryBytes
}

/**
 * Reads `whisper_models.json`, which `WhisperCppAndroidExportTests` generates from SpeakCore, so the
 * models, URLs and checksums are never copied by hand.
 */
object WhisperCatalog {
    const val ASSET = "whisper_models.json"

    fun parse(json: String): List<WhisperModel> {
        val models = JSONObject(json).getJSONArray("models")
        return (0 until models.length()).map { index ->
            val model = models.getJSONObject(index)
            val hosts = model.getJSONArray("allowedHosts")
            WhisperModel(
                catalogId = model.getString("catalogId"),
                displayName = model.getString("displayName"),
                summary = model.getString("summary"),
                quantization = model.getString("quantization"),
                multilingual = model.getBoolean("multilingual"),
                url = model.getString("url"),
                filename = model.getString("filename"),
                bytes = model.getLong("bytes"),
                sha256 = model.getString("sha256").lowercase(Locale.ROOT),
                license = model.getString("license"),
                allowedHosts = (0 until hosts.length()).map(hosts::getString),
                minimumDeviceMemoryBytes = if (model.isNull("minimumDeviceMemoryBytes")) {
                    null
                } else {
                    model.getLong("minimumDeviceMemoryBytes")
                },
            ).also(::requireSafe)
        }
    }

    /**
     * The models this phone offers: those that fit its memory, plus any already downloaded, so a
     * downloaded model can always be removed.
     */
    fun offered(models: List<WhisperModel>, totalMemoryBytes: Long, installed: Set<String>): List<WhisperModel> =
        models.filter { it.fitsDevice(totalMemoryBytes) || it.catalogId in installed }

    fun find(models: List<WhisperModel>, id: String?): WhisperModel? = models.firstOrNull { it.catalogId == id }

    private fun requireSafe(model: WhisperModel) {
        val uri = URI(model.url)
        require(uri.scheme == "https" && model.allowsHost(uri.host.orEmpty())) { "Untrusted model URL" }
        require(model.bytes > 0 && SHA256.matches(model.sha256)) { "Missing integrity pins" }
        require(FILENAME.matches(model.filename)) { "Unsafe model filename" }
    }

    private val SHA256 = Regex("[0-9a-f]{64}")
    private val FILENAME = Regex("[A-Za-z0-9._-]+\\.bin")
}
