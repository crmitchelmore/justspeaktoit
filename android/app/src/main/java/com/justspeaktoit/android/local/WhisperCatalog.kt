package com.justspeaktoit.android.local

import org.json.JSONObject
import java.util.Locale

/**
 * A downloadable whisper.cpp model, from SpeakCore's `WhisperCppModels` pins. [catalogId] is the shared
 * `local/whisperkit/...` identifier every platform stores.
 */
data class WhisperModel(
    override val catalogId: String,
    override val displayName: String,
    override val summary: String,
    val quantization: String,
    val multilingual: Boolean,
    override val url: String,
    override val filename: String,
    override val bytes: Long,
    override val sha256: String,
    override val license: String,
    override val allowedHosts: List<String>,
    override val minimumDeviceMemoryBytes: Long?,
) : PinnedModel

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
            ).also { PinnedModels.requireSafe(it, FILENAME) }
        }
    }

    /** See [PinnedModels.offered]. */
    fun offered(models: List<WhisperModel>, totalMemoryBytes: Long, installed: Set<String>): List<WhisperModel> =
        PinnedModels.offered(models, totalMemoryBytes, installed)

    fun find(models: List<WhisperModel>, id: String?): WhisperModel? = PinnedModels.find(models, id)

    private val FILENAME = Regex("[A-Za-z0-9._-]+\\.bin")
}
