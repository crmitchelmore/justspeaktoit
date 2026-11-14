package com.justspeaktoit.android.transfer

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.dictation.DictationLanguages
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.security.SecretStore
import com.justspeaktoit.android.settings.DictationPreferences
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.OutputStream

/** What an export wrote, for the confirmation. */
internal data class ExportSummary(val categories: List<TransferCategory>, val recordings: Int)

/**
 * Writes Android's configuration as the shared archive: settings always; History, recordings,
 * profiles and corrections when there are any; API keys only when [includeCredentials] is set.
 * Android has no connections or model downloads, so those categories are never written.
 */
internal object ConfigExporter {
    /**
     * Throws `GeneralSecurityException` or `ProviderException` when an API key cannot be read, and
     * IOException when the archive cannot be written; either way the export did not finish.
     */
    fun export(
        output: OutputStream,
        prefs: DictationPreferences,
        history: List<HistoryEntry>,
        secrets: SecretStore,
        includeCredentials: Boolean,
        nowMs: Long,
    ): ExportSummary {
        val records = mutableMapOf<TransferCategory, List<ArchiveRecord>>()
        records[TransferCategory.Settings] = settings(prefs)
        if (history.isNotEmpty()) records[TransferCategory.History] = history.map(HistoryRecords::record)
        val audio = linkedMapOf<String, ArchiveAudio>()
        val recordings = history.mapNotNull { entry -> recording(entry, audio) }
        if (recordings.isNotEmpty()) records[TransferCategory.Recordings] = recordings
        val profiles = prefs.profiles.mapNotNull(ProfileRecords::record)
        if (profiles.isNotEmpty()) records[TransferCategory.Profiles] = profiles
        val corrections = prefs.corrections.map { LexiconRecords.record(it, nowMs) }
        if (corrections.isNotEmpty()) records[TransferCategory.Vocabulary] = corrections
        if (includeCredentials) {
            val keys = CloudProvider.entries.mapNotNull { provider ->
                secrets.read(provider.credentialId)?.takeIf { it.isNotBlank() }?.let {
                    ArchiveRecord(id = provider.credentialId, kind = RecordKinds.SECRET, value = it)
                }
            }
            if (keys.isNotEmpty()) records[TransferCategory.Credentials] = keys
        }
        val manifest = ArchiveManifest(
            version = ArchiveFormat.VERSION,
            createdAtMs = nowMs,
            categories = TransferCategory.entries.filter { it in records },
        )
        val extras = mapOf(ArchiveFormat.ANDROID_SETTINGS to androidSettings(prefs).toString().toByteArray(Charsets.UTF_8))
        ConfigArchiveWriter.write(output, manifest, records, audio, extras)
        return ExportSummary(manifest.categories, recordings.size)
    }

    private fun settings(prefs: DictationPreferences): List<ArchiveRecord> = listOf(
        SharedSettings.KEEP_AUDIO to prefs.keepAudioOnCancel,
        SharedSettings.CLEANUP_ENABLED to prefs.cleanupEnabled,
        SharedSettings.LANGUAGE to DictationLanguages.normalized(prefs.languageId),
        SharedSettings.CLEANUP_MODEL to CloudCatalog.cleanupModel(prefs.cleanupModelId).selectionId,
        SharedSettings.CLOUD_MODEL to CloudCatalog.transcriptionModel(prefs.cloudModelId).catalogId,
    ).map { (key, value) -> ArchiveRecord(id = key, kind = RecordKinds.SETTING, value = value) }

    private fun androidSettings(prefs: DictationPreferences): JSONObject {
        val active = prefs.activeProfileId?.let { id ->
            prefs.profiles.firstOrNull { it.id == id }?.let { ProfileRecords.record(it)?.id }
        }
        return JSONObject()
            .put("version", AndroidSettings.VERSION)
            .put(AndroidSettings.MODE, prefs.chosenMode?.name ?: JSONObject.NULL)
            .put(AndroidSettings.RETENTION, prefs.retention.name)
            .put(AndroidSettings.PROMPT, prefs.cleanupPrompt?.takeIf { it.isNotBlank() } ?: JSONObject.NULL)
            .put(AndroidSettings.PROFILE, active ?: JSONObject.NULL)
    }

    /** A kept recording that has gone (for example deleted meanwhile) is left out, not a failure. */
    private fun recording(entry: HistoryEntry, audio: MutableMap<String, ArchiveAudio>): ArchiveRecord? {
        val file = entry.audioPath?.let(::File)?.takeIf { it.isFile } ?: return null
        val measured = try {
            ArchiveAudio.measure(file)
        } catch (_: IOException) {
            return null
        }
        val id = HistoryRecords.exportId(entry.id)
        val path = "${ArchiveFormat.RECORDINGS_DIRECTORY}/$id-${measured.sha256.take(SHORT_DIGEST)}.wav"
        audio[path] = measured
        val value = HistoryRecords.value(entry, id, audioOnly = true)
        return ArchiveRecord(
            id = id,
            kind = RecordKinds.AUDIO,
            value = value,
            dateMs = entry.createdAtMs,
            file = path,
            digest = measured.sha256,
            revision = measured.sha256,
        )
    }

    private const val SHORT_DIGEST = 12
}
