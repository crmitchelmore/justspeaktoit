package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.history.HistoryAudio
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.history.HistoryStore
import com.justspeaktoit.android.history.Retention
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * Owns History for a dictation screen: the ordered writes, the entry of the latest session (so a
 * cleanup or "Show original" replaces it rather than adding another) and cancelled recordings kept
 * for a later transcription. Call from the main thread of [scope]; every change is applied on one
 * IO thread, in call order, and each result is handed to [publish] on [scope].
 */
internal class DictationHistory(
    private val store: HistoryStore,
    private val recordingsDir: File,
    private val scope: CoroutineScope,
    io: CoroutineDispatcher,
    private val now: () -> Long = System::currentTimeMillis,
    private val newId: () -> String = { UUID.randomUUID().toString() },
    private val publish: (entries: List<HistoryEntry>, failed: Boolean) -> Unit,
) {
    // One thread owns the history file, so writes are ordered without locks.
    @OptIn(ExperimentalCoroutinesApi::class)
    private val writer = io.limitedParallelism(1)

    /** The latest session's entry, so a later cleanup updates it rather than adding another. */
    private var sessionEntry: HistoryEntry? = null

    /** Loads History and deletes audio no entry refers to (for example after a crash mid-save). */
    fun load(retention: Retention): Job = update {
        store.load(retention).also { entries ->
            val stored = recordingsDir.listFiles().orEmpty().map { it.absolutePath }
            HistoryAudio.orphans(stored, entries).forEach { File(it).delete() }
        }
    }

    /** Re-reads and prunes, so the retention cutoff holds while the app stays open. */
    fun refresh(retention: Retention): Job = update { store.load(retention) }

    fun remove(id: String, retention: Retention): Job = update { store.remove(id, retention) }

    fun clear(): Job = update { store.clear() }

    /** Records a session that just ended. Only Done and Failed sessions are recorded. */
    fun recordSession(state: DictationState, modelId: String?, retention: Retention): Job? {
        val entry = when (state) {
            is DictationState.Done -> sessionEntry(state.mode, modelId, HistoryStatus.Completed, state.transcript, null)
            is DictationState.Failed ->
                sessionEntry(state.mode, modelId, HistoryStatus.Failed, state.unfinishedText, state.failure)
            else -> return null
        }
        sessionEntry = entry
        return update { store.add(entry, retention) }
    }

    /** Replaces the latest session's text, after a cleanup or when the user restores the original. */
    fun replaceSessionText(text: String, cleanedUp: Boolean, retention: Retention): Job? {
        val entry = sessionEntry?.copy(text = text, cleanedUp = cleanedUp) ?: return null
        sessionEntry = entry
        return update { store.replace(entry, retention) }
    }

    /**
     * Moves a stopped recording into History as a cancelled entry, ready for [replace] after a later
     * transcription. If the audio cannot be moved it is deleted and History is left unchanged.
     */
    fun keepRecording(file: File, modelId: String?, retention: Retention): Job {
        val id = newId()
        return update {
            val kept = File(recordingsDir, "$id.wav")
            if (!moveRecording(file, kept)) {
                file.delete()
                return@update store.cached
            }
            val entry = HistoryEntry(
                id = id,
                createdAtMs = now(),
                mode = RecognitionMode.Cloud.name,
                model = modelId,
                status = HistoryStatus.Cancelled,
                text = "",
                audioPath = kept.absolutePath,
            )
            store.add(entry, retention)
        }
    }

    /** Replaces an entry and returns once the change is written and published. */
    suspend fun replace(entry: HistoryEntry, retention: Retention) = apply { store.replace(entry, retention) }

    private fun update(change: () -> List<HistoryEntry>): Job = scope.launch { apply(change) }

    private suspend fun apply(change: () -> List<HistoryEntry>) {
        val (entries, failed) = withContext(writer) {
            try {
                change() to false
            } catch (e: IOException) {
                store.cached to true
            }
        }
        publish(entries, failed)
    }

    private fun sessionEntry(
        mode: RecognitionMode,
        modelId: String?,
        status: HistoryStatus,
        text: String,
        failure: DictationFailure?,
    ) = HistoryEntry(
        id = newId(),
        createdAtMs = now(),
        mode = mode.name,
        model = if (mode == RecognitionMode.Cloud) modelId else null,
        status = status,
        text = text,
        failure = failure?.name,
    )

    private fun moveRecording(source: File, target: File): Boolean {
        target.parentFile?.mkdirs()
        if (source.renameTo(target)) return true
        return try {
            source.copyTo(target, overwrite = true)
            source.delete()
            true
        } catch (e: IOException) {
            target.delete()
            false
        }
    }
}
