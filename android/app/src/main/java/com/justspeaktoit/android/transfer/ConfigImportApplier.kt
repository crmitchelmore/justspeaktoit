package com.justspeaktoit.android.transfer

import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.security.SecretStore
import com.justspeaktoit.android.settings.DictationPreferences
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.ProviderException
import java.util.UUID

/**
 * Applies an [ImportPlan] all or nothing. Recordings, API keys and History are the steps that can
 * fail, so they go first and each is undone if a later one fails; settings are written last, once
 * nothing else can fail.
 */
internal class ConfigImportApplier(
    private val prefs: DictationPreferences,
    private val secrets: SecretStore,
    private val recordingsDir: File,
    private val io: CoroutineDispatcher,
    /** Writes History in one step: given the retention and the change, or throws [IOException]. */
    private val commitHistory: suspend (Retention, (List<HistoryEntry>) -> List<HistoryEntry>) -> List<HistoryEntry>,
) {
    /** True when everything was applied; false when nothing was. API keys are written only when [includeCredentials]. */
    suspend fun applyPlan(plan: ImportPlan, includeCredentials: Boolean): Boolean {
        val moved = withContext(io) { moveAudio(plan.audio) } ?: return false
        val credentials = if (includeCredentials) plan.credentials else emptyMap()
        val previous = withContext(io) { writeSecrets(credentials) }
        if (previous == null) {
            withContext(io) { moved.values.forEach { it.delete() } }
            return false
        }
        val retention = plan.settings.retention ?: prefs.retention
        if ((plan.history.isNotEmpty() || moved.isNotEmpty()) && retention != Retention.Off) {
            val paths = moved.mapValues { it.value.absolutePath }
            val entries = try {
                commitHistory(retention) { existing -> ConfigImporter.mergeHistory(existing, plan.history, paths) }
            } catch (_: IOException) {
                withContext(io) {
                    restoreSecrets(previous)
                    moved.values.forEach { it.delete() }
                }
                return false
            }
            val kept = entries.mapNotNullTo(mutableSetOf()) { it.audioPath }
            withContext(io) { moved.values.filterNot { it.absolutePath in kept }.forEach { it.delete() } }
        } else {
            withContext(io) { moved.values.forEach { it.delete() } }
        }
        writePreferences(plan)
        return true
    }

    /** Moves each staged recording beside the others; null, with nothing moved, if one cannot be. */
    private fun moveAudio(audio: Map<String, File>): Map<String, File>? {
        val moved = linkedMapOf<String, File>()
        audio.forEach { (id, staged) ->
            recordingsDir.mkdirs()
            val target = File(recordingsDir, "${UUID.randomUUID()}.wav")
            val ok = staged.renameTo(target) || try {
                staged.copyTo(target)
                true
            } catch (_: IOException) {
                false
            }
            if (!ok) {
                target.delete()
                moved.values.forEach { it.delete() }
                return null
            }
            moved[id] = target
        }
        return moved
    }

    /**
     * Writes [values] and returns what each name held before (null where it held nothing), so they
     * can be restored. Returns null, with every key as it was, when one cannot be read or written.
     */
    private fun writeSecrets(values: Map<String, String>): Map<String, String?>? {
        val previous = linkedMapOf<String, String?>()
        try {
            values.keys.forEach { previous[it] = secrets.read(it) }
        } catch (_: GeneralSecurityException) {
            return null
        } catch (_: ProviderException) {
            return null
        } catch (_: IOException) {
            return null
        }
        val written = linkedMapOf<String, String?>()
        values.forEach { (name, value) ->
            val ok = try {
                secrets.write(name, value)
                true
            } catch (_: GeneralSecurityException) {
                false
            } catch (_: ProviderException) {
                false
            } catch (_: IOException) {
                false
            }
            // The failed write may have changed the stored value, so it is restored too.
            written[name] = previous[name]
            if (!ok) {
                restoreSecrets(written)
                return null
            }
        }
        return previous
    }

    /** Best effort: a key that cannot be restored is left as the import wrote it. */
    private fun restoreSecrets(previous: Map<String, String?>) {
        previous.forEach { (name, value) ->
            try {
                if (value == null) secrets.remove(name) else secrets.write(name, value)
            } catch (_: GeneralSecurityException) {
            } catch (_: ProviderException) {
            } catch (_: IOException) {
            }
        }
    }

    private fun writePreferences(plan: ImportPlan) {
        val settings = plan.settings
        settings.keepAudioOnCancel?.let { prefs.keepAudioOnCancel = it }
        settings.cleanupEnabled?.let { prefs.cleanupEnabled = it }
        settings.languageId?.let { prefs.languageId = it }
        settings.cleanupModelId?.let { prefs.cleanupModelId = it }
        settings.cloudModelId?.let { prefs.cloudModelId = it }
        settings.chosenMode?.let { prefs.chosenMode = it.value }
        settings.cleanupPrompt?.let { prefs.cleanupPrompt = it.value }
        plan.profiles?.let { prefs.profiles = it }
        plan.corrections?.let { prefs.corrections = it }
        settings.activeProfileId?.let { prefs.activeProfileId = it.value }
        settings.retention?.let { prefs.retention = it }
    }
}
