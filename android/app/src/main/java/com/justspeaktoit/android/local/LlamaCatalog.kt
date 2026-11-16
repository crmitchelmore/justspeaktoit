package com.justspeaktoit.android.local

import org.json.JSONObject
import java.util.Locale

/**
 * A downloadable llama.cpp cleanup model, from SpeakCore's `LlamaCppModels` pins over
 * `ModelCatalog.localPostProcessing`. [catalogId] is the shared `local/post-processing/...` identifier
 * the Mac, Windows and Linux store for the same model.
 */
data class LlamaModel(
    override val catalogId: String,
    override val displayName: String,
    override val summary: String,
    val repository: String,
    val revision: String,
    override val url: String,
    override val filename: String,
    override val bytes: Long,
    override val sha256: String,
    override val license: String,
    override val allowedHosts: List<String>,
    override val minimumDeviceMemoryBytes: Long?,
) : PinnedModel

/**
 * Reads `cleanup_models.json`, which `LlamaCppAndroidExportTests` generates from SpeakCore, so the
 * models, URLs and checksums are never copied by hand.
 */
object LlamaCatalog {
    const val ASSET = "cleanup_models.json"

    /** Every downloaded cleanup model shares this prefix with the desktop catalogue. */
    const val ID_PREFIX = "local/post-processing/"

    fun parse(json: String): List<LlamaModel> {
        val models = JSONObject(json).getJSONArray("models")
        return (0 until models.length()).map { index ->
            val model = models.getJSONObject(index)
            val hosts = model.getJSONArray("allowedHosts")
            LlamaModel(
                catalogId = model.getString("catalogId"),
                displayName = model.getString("displayName"),
                summary = model.getString("summary"),
                repository = model.getString("repository"),
                revision = model.getString("revision"),
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
            ).also {
                require(it.catalogId.startsWith(ID_PREFIX)) { "Not a local cleanup model" }
                PinnedModels.requireSafe(it, FILENAME)
            }
        }
    }

    private val FILENAME = Regex("[A-Za-z0-9._-]+\\.gguf")
}
