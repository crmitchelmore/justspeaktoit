package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.RecordingRecovery
import com.justspeaktoit.android.history.HistoryAudio
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.history.HistoryStore
import com.justspeaktoit.android.history.Retention
import kotlinx.coroutines.CancellationException
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
 * IO thread, in call order, and each result is handed to [publish] on [scope]. [onLocalChange] runs
 * after each change made on this device, but not after one received through History sync.
 */
internal class DictationHistory(
    private val store: HistoryStore,
    private val recordingsDir: File,
    private val scope: CoroutineScope,
    io: CoroutineDispatcher,
    private val now: () -> Long = System::currentTimeMillis,
    private val newId: () -> String = { UUID.randomUUID().toString() },
    private val onLocalChange: () -> Unit = {},
    private val publish: (entries: List<HistoryEntry>, failed: Boolean) -> Unit,
) {
    // One thread owns the history file, so writes are ordered without locks.
    @OptIn(ExperimentalCoroutinesApi::class)
    private val writer = io.limitedParallelism(1)

    /** The latest session's entry, so a later cleanup updates it rather than adding another. */
    private var sessionEntry: HistoryEntry? = null

    /** The latest change; the next one waits for it, so changes publish in call order. */
    private var last: Job? = null

    /** The entry [recordSession] wrote last, so an interrupted recording can be attached to it. */
    val latestSession: HistoryEntry? get() = sessionEntry

    /**
     * Loads History, saves the [recoverable] recordings no session finished, and deletes audio no
     * entry refers to (for example after a crash mid-save). [recoverable] runs on the History thread.
     */
    fun load(retention: Retention, recoverable: () -> List<File> = { emptyList() }): Job = update(local = false) {
        store.load(retention)
        recover(recoverable(), retention).also { entries ->
            val stored = recordingsDir.listFiles().orEmpty().map { it.absolutePath }
            HistoryAudio.orphans(stored, entries).forEach { File(it).delete() }
        }
    }

    /** Re-reads and prunes, so the retention cutoff holds while the app stays open. */
    fun refresh(retention: Retention, recoverable: () -> List<File> = { emptyList() }): Job = update(local = false) {
        store.load(retention)
        recover(recoverable(), retention)
    }

    fun remove(id: String, retention: Retention): Job = update { store.remove(id, retention) }

    /** Clears History; [keepRecordings] keeps the entries holding audio so it can still be played. */
    fun clear(keepRecordings: Boolean = false, retention: Retention = Retention.Forever): Job =
        update { if (keepRecordings) store.clearKeepingRecordings(retention) else store.clear() }

    /**
     * Records a session that just ended. Only Done and Failed sessions are recorded, and [audio] (a
     * stopped recording) is moved into History beside the entry; it is deleted if it cannot be kept.
     */
    fun recordSession(state: DictationState, modelId: String?, retention: Retention, audio: File? = null): Job? {
        val base = when (state) {
            is DictationState.Done -> sessionEntry(state.mode, modelId, HistoryStatus.Completed, state.transcript, null)
            is DictationState.Failed ->
                sessionEntry(state.mode, modelId, HistoryStatus.Failed, state.unfinishedText, state.failure)
            else -> {
                audio?.delete()
                return null
            }
        }
        val kept = audio?.let { File(recordingsDir, "${base.id}.wav") }
        val entry = base.copy(audioPath = kept?.absolutePath)
        sessionEntry = entry
        return update {
            if (audio == null || kept == null) return@update store.add(entry, retention)
            if (!moveRecording(audio, kept)) {
                audio.delete()
                return@update store.add(base, retention)
            }
            store.add(entry, retention).also { entries ->
                // History is off, so the recording has nowhere to live.
                if (entries.none { it.audioPath == kept.absolutePath }) kept.delete()
            }
        }
    }

    /** Replaces the latest session's text, after a cleanup or when the user restores the original. */
    fun replaceSessionText(text: String, cleanedUp: Boolean, retention: Retention): Job? {
        val prior = sessionEntry ?: return null
        // Keeps the transcript a cleanup replaced, so History sync can send it as the raw text.
        val rawText = when {
            !cleanedUp -> null
            prior.cleanedUp -> prior.rawText
            else -> prior.text
        }
        val entry = prior.copy(text = text, cleanedUp = cleanedUp, rawText = rawText)
        sessionEntry = entry
        return update {
            // The stored entry knows whether its recording was really kept or attached later.
            val stored = store.cached.firstOrNull { it.id == entry.id }
            store.replace(entry.copy(audioPath = stored?.audioPath), retention)
        }
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

    /**
     * Moves an interrupted session's stopped recording into History beside its entry, so it can be
     * transcribed later. Runs after [recordSession] wrote [entry]; too short a recording is deleted.
     */
    fun attachAudio(file: File, entry: HistoryEntry?, retention: Retention): Job =
        update {
            if (entry == null || RecordingRecovery.finalise(file) < 0) {
                file.delete()
                return@update store.cached
            }
            val kept = File(recordingsDir, "${entry.id}.wav")
            if (!moveRecording(file, kept)) {
                file.delete()
                return@update store.cached
            }
            val updated = entry.copy(audioPath = kept.absolutePath)
            val entries = store.replace(updated, retention)
            // The entry was pruned or removed meanwhile, so nothing refers to the audio.
            if (entries.none { it.audioPath == kept.absolutePath }) kept.delete()
            entries
        }

    /** Replaces an entry and returns once the change is written and published. */
    suspend fun replace(entry: HistoryEntry, retention: Retention) = update { store.replace(entry, retention) }.join()

    /**
     * Applies an imported History in one write and publishes it. Throws [IOException], leaving
     * History unchanged, when it cannot be written.
     */
    suspend fun importEntries(
        retention: Retention,
        change: (List<HistoryEntry>) -> List<HistoryEntry>,
    ): List<HistoryEntry> {
        val entries = withContext(writer) { store.replaceAll(retention, change) }
        publish(entries, false)
        // An imported History is this device's change, so History sync uploads it.
        onLocalChange()
        return entries
    }

    /** The current entries, read on the History thread so no write is in progress. */
    suspend fun snapshot(retention: Retention): List<HistoryEntry> = withContext(writer) { store.snapshot(retention) }

    /** The current entries, read on the History thread. */
    suspend fun syncSnapshot(retention: Retention): List<HistoryEntry> = withContext(writer) { store.entries(retention) }

    /**
     * Applies changes received through History sync in one write and publishes the result, without
     * running [onLocalChange]. Queued behind earlier changes like any other, so results publish in
     * order. Throws [IOException] when the write fails. Callable from any thread.
     */
    suspend fun <T> syncUpdate(
        retention: Retention,
        transform: (List<HistoryEntry>) -> Pair<List<HistoryEntry>, T>,
    ): T {
        var outcome: Result<T>? = null
        // [update] reads and sets [last], which only the scope's thread may touch.
        scope.launch {
            update(local = false) {
                val (next, result) = try {
                    transform(store.entries(retention))
                } catch (e: Exception) {
                    outcome = Result.failure(e)
                    return@update store.cached
                }
                try {
                    store.replaceAll(next, retention).also { outcome = Result.success(result) }
                } catch (e: IOException) {
                    outcome = Result.failure(e)
                    throw e
                }
            }.join()
        }.join()
        return (outcome ?: throw CancellationException("History closed")).getOrThrow()
    }

    /** Saves each recording as a failed Cloud entry with its audio, ready to transcribe. */
    private fun recover(files: List<File>, retention: Retention): List<HistoryEntry> {
        var entries = store.cached
        files.forEach { file ->
            val createdAt = file.lastModified().takeIf { it > 0 } ?: now()
            if (RecordingRecovery.finalise(file) < 0) {
                file.delete()
                return@forEach
            }
            val id = newId()
            val kept = File(recordingsDir, "$id.wav")
            if (!moveRecording(file, kept)) {
                file.delete()
                return@forEach
            }
            val entry = HistoryEntry(
                id = id,
                createdAtMs = createdAt,
                mode = RecognitionMode.Cloud.name,
                model = null,
                status = HistoryStatus.Failed,
                text = "",
                failure = DictationFailure.RecordingRecovered.name,
                audioPath = kept.absolutePath,
            )
            entries = store.add(entry, retention)
            // History is off, so the recording has nowhere to live.
            if (entries.none { it.id == id }) kept.delete()
        }
        return entries
    }

    /**
     * Chains each change after the previous one. Writes alone are ordered by [writer], but when a
     * write finishes before its caller suspends, `withContext` returns at once and that change can
     * publish ahead of an earlier one whose resumption is still queued on [scope].
     */
    private fun update(local: Boolean = true, change: () -> List<HistoryEntry>): Job {
        val previous = last
        return scope.launch {
            previous?.join()
            apply(local, change)
        }.also { last = it }
    }

    private suspend fun apply(local: Boolean, change: () -> List<HistoryEntry>) {
        val (entries, failed) = withContext(writer) {
            try {
                change() to false
            } catch (e: IOException) {
                store.cached to true
            }
        }
        publish(entries, failed)
        if (local) onLocalChange()
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
