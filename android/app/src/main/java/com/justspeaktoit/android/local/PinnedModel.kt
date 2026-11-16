package com.justspeaktoit.android.local

import java.net.URI
import java.util.Locale

/**
 * A downloadable model file pinned by SpeakCore: its exact URL, size and SHA-256. [catalogId] is the
 * shared `local/...` identifier every platform stores, so a choice survives a configuration transfer.
 * [minimumDeviceMemoryBytes] is set when the model is offered only on phones with at least that much
 * memory. Whisper transcription models and llama.cpp cleanup models share one store, downloader and
 * manager through this.
 */
interface PinnedModel {
    val catalogId: String
    val displayName: String
    val summary: String
    val url: String
    val filename: String
    val bytes: Long
    val sha256: String
    val license: String
    val allowedHosts: List<String>
    val minimumDeviceMemoryBytes: Long?

    /** As `LocalModelDownloadRequest.allows(host:)`: an exact host, or a subdomain of a `.suffix` entry. */
    fun allowsHost(host: String): Boolean {
        val lower = host.lowercase(Locale.ROOT)
        if (lower.isEmpty()) return false
        return allowedHosts.any { allowed ->
            if (allowed.startsWith(".")) lower.endsWith(allowed) else lower == allowed
        }
    }

    fun fitsDevice(totalMemoryBytes: Long): Boolean =
        minimumDeviceMemoryBytes.let { it == null || totalMemoryBytes >= it }
}

/** Shared rules for pinned-model catalogues read from SpeakCore's exported assets. */
object PinnedModels {
    /**
     * The models this phone offers: those that fit its memory, plus any already downloaded, so a
     * downloaded model can always be removed.
     */
    fun <M : PinnedModel> offered(models: List<M>, totalMemoryBytes: Long, installed: Set<String>): List<M> =
        models.filter { it.fitsDevice(totalMemoryBytes) || it.catalogId in installed }

    fun <M : PinnedModel> find(models: List<M>, id: String?): M? = models.firstOrNull { it.catalogId == id }

    /** Rejects a pin that is not HTTPS to an allowed host, lacks integrity fields or names an unsafe file. */
    fun requireSafe(model: PinnedModel, filename: Regex) {
        val uri = URI(model.url)
        require(uri.scheme == "https" && model.allowsHost(uri.host.orEmpty())) { "Untrusted model URL" }
        require(model.bytes > 0 && SHA256.matches(model.sha256)) { "Missing integrity pins" }
        require(filename.matches(model.filename)) { "Unsafe model filename" }
    }

    private val SHA256 = Regex("[0-9a-f]{64}")
}
