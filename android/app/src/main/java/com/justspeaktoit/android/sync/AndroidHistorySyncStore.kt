package com.justspeaktoit.android.sync

import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException
import java.util.Locale
import java.util.UUID

/** Android History as the sync side sees it; production runs both on the History thread. */
interface SyncHistoryEntries {
    suspend fun snapshot(): List<HistoryEntry>

    /** Replaces the entries with [transform]'s list in one write; throws [IOException] when it is not saved. */
    suspend fun <T> update(transform: (List<HistoryEntry>) -> Pair<List<HistoryEntry>, T>): T
}

/** How an Android History entry maps to the shared record (desktop `DesktopHistorySyncProjection`). */
object HistorySyncProjection {
    const val ORIGIN_PLATFORM = "android"
    const val SYNCED_MODE = "Synced"

    fun isSyncable(entry: HistoryEntry): Boolean =
        entry.status == HistoryStatus.Completed && entry.text.isNotEmpty() && HistorySchema.canonicalId(entry.id) != null

    /** A copy received from another device: it has a remote origin and never has audio. */
    fun isSyncedCopy(entry: HistoryEntry): Boolean = entry.originPlatform != null && entry.audioPath == null

    fun entry(entry: HistoryEntry, updatedAtMs: Long): SyncableHistoryEntry {
        val id = requireNotNull(HistorySchema.canonicalId(entry.id)) { "History entry ${entry.id} is not a UUID." }
        return SyncableHistoryEntry(
            id = id,
            createdAtMs = entry.createdAtMs,
            rawTranscription = raw(entry),
            postProcessedText = if (entry.cleanedUp) entry.text else null,
            model = entry.model ?: localModel(entry.mode),
            duration = entry.durationSeconds ?: 0.0,
            // The Mac counts space-separated words the same way.
            wordCount = entry.text.split(' ').count { it.isNotEmpty() },
            originPlatform = entry.originPlatform ?: ORIGIN_PLATFORM,
            updatedAtMs = updatedAtMs,
        )
    }

    /** FNV-1a 64 over the synced fields, exactly as the desktop store fingerprints them. */
    fun fingerprint(entry: SyncableHistoryEntry): String {
        val parts = listOf(
            entry.id,
            entry.createdAtMs.toString(),
            entry.rawTranscription?.let { "r$it" } ?: "-",
            entry.postProcessedText?.let { "p$it" } ?: "-",
            entry.model,
            java.lang.Long.toUnsignedString(entry.duration.toRawBits()),
            entry.wordCount.toString(),
            entry.originPlatform,
        )
        var hash = FNV_OFFSET
        parts.joinToString("\u001F").toByteArray(Charsets.UTF_8).forEach { byte ->
            hash = hash xor (byte.toLong() and 0xFF)
            hash *= FNV_PRIME
        }
        return java.lang.Long.toUnsignedString(hash, 16)
    }

    /** Applies a remote copy, keeping what only this device knows (desktop `DesktopHistorySyncStore.merge`). */
    fun merge(remote: SyncableHistoryEntry, existing: HistoryEntry?): HistoryEntry {
        if (existing == null) {
            val processed = remote.postProcessedText
            return HistoryEntry(
                id = remote.id.lowercase(Locale.ROOT),
                createdAtMs = remote.createdAtMs,
                mode = SYNCED_MODE,
                model = remote.model,
                status = HistoryStatus.Completed,
                text = processed ?: remote.rawTranscription.orEmpty(),
                cleanedUp = processed != null,
                rawText = if (processed != null) remote.rawTranscription else null,
                durationSeconds = remote.duration,
                originPlatform = remote.originPlatform,
            )
        }
        val rawText = remote.rawTranscription ?: if (isSyncedCopy(existing)) null else raw(existing)
        val processed = remote.postProcessedText
        return existing.copy(
            status = HistoryStatus.Completed,
            failure = null,
            text = processed ?: rawText.orEmpty(),
            cleanedUp = processed != null,
            rawText = if (processed != null) rawText else null,
            durationSeconds = existing.durationSeconds ?: remote.duration,
            model = existing.model ?: remote.model,
        )
    }

    private fun raw(entry: HistoryEntry): String? = if (entry.cleanedUp) entry.rawText else entry.text

    private fun localModel(mode: String): String = when (mode) {
        "OnDevice" -> "android/on-device"
        "SpeechService" -> "android/speech-service"
        else -> "android"
    }

    private const val FNV_OFFSET = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
    private const val FNV_PRIME = 0x100000001b3L
}

/** A deletion still to be sent to [account]'s iCloud. */
data class PendingHistoryDeletion(val id: String, val account: String, val revision: String)

/**
 * Android's [HistorySyncLocalStore], a port of `DesktopHistorySyncStore` plus the desktop deletion
 * ledger. Received changes are staged and written to History in one save by [persistRemoteChanges],
 * so a whole change page costs one write.
 */
class AndroidHistorySyncStore(
    private val entries: SyncHistoryEntries,
    private val stateFile: HistorySyncStateFile,
    private val now: () -> Long = System::currentTimeMillis,
    private val newRevision: () -> String = { UUID.randomUUID().toString().uppercase(Locale.ROOT) },
) : HistorySyncLocalStore {
    private val lock = Mutex()
    private var loaded: HistorySyncState? = null
    private val offered = mutableMapOf<String, String>()
    private val staged = linkedMapOf<String, SyncableHistoryEntry?>()
    private var unapplied = 0

    suspend fun state(): HistorySyncState = lock.withLock { current() }

    /** Saves [transform]'s state; the in-memory state changes only once it is written. */
    suspend fun updateState(transform: (HistorySyncState) -> HistorySyncState): HistorySyncState =
        lock.withLock { commit(transform(current())) }

    override suspend fun loadCursor(): String? = state().cursor

    override suspend fun saveCursor(token: String) {
        updateState { it.copy(cursor = token) }
    }

    override suspend fun pendingEntries(): List<SyncableHistoryEntry> {
        val snapshot = entries.snapshot()
        return lock.withLock {
            val state = current()
            val stamp = now()
            val syncable = snapshot.filter {
                HistorySyncProjection.isSyncable(it) && HistorySchema.canonicalId(it.id) !in state.deletions
            }
            val history = state.history.toMutableMap()
            for (entry in syncable) {
                val id = HistorySchema.canonicalId(entry.id) ?: continue
                val previous = history[id]
                val fingerprint = HistorySyncProjection.fingerprint(HistorySyncProjection.entry(entry, stamp))
                history[id] = when {
                    previous == null ->
                        // First sight: an entry that predates sync keeps its creation time, so any remote copy wins.
                        HistoryEntrySyncState(null, fingerprint, entry.createdAtMs)
                    previous.observed != fingerprint ->
                        previous.copy(observed = fingerprint, updatedAtMs = maxOf(stamp, previous.updatedAtMs))
                    else -> previous
                }
            }
            val observed = if (history == state.history) state.history else commit(state.copy(history = history)).history
            syncable.mapNotNull { entry ->
                val id = HistorySchema.canonicalId(entry.id) ?: return@mapNotNull null
                val s = observed[id] ?: return@mapNotNull null
                if (s.deletedElsewhere || s.acknowledged == s.observed) return@mapNotNull null
                offered[id] = s.observed
                HistorySyncProjection.entry(entry, s.updatedAtMs)
            }.sortedBy { it.createdAtMs }
        }
    }

    override suspend fun didReceiveRemoteEntry(entry: SyncableHistoryEntry) {
        lock.withLock {
            val state = current()
            val intent = state.deletions[entry.id]
            if (intent != null) {
                // Deleted here: send the deletion again rather than restore the entry.
                offered.remove(entry.id)
                val account = state.account
                if (state.enabled && account != null && intent.account == account && !intent.cloudPending) {
                    val requeued = intent.copy(revision = newRevision(), cloudPending = true)
                    try {
                        commit(state.copy(deletions = state.deletions + (entry.id to requeued)))
                    } catch (e: IOException) {
                        unapplied += 1
                    }
                }
                return
            }
            val local = state.history[entry.id]
            // A newer local edit is waiting to upload; it wins.
            if (local != null && local.updatedAtMs > entry.updatedAtMs && local.acknowledged != local.observed) return
            // CloudKit's copy replaces whatever was offered, so a later acknowledgement must not mark it synced.
            offered.remove(entry.id)
            staged[entry.id] = entry
        }
    }

    override suspend fun didDeleteRemoteEntry(id: String) {
        lock.withLock {
            if (id in current().deletions) return
            staged[id] = null
        }
    }

    override suspend fun didAcknowledge(ids: Set<String>) {
        lock.withLock {
            val state = current()
            val confirmed = mutableMapOf<String, String>()
            for (id in ids) {
                val fingerprint = offered.remove(id)
                if (fingerprint != null && id !in state.deletions) confirmed[id] = fingerprint
            }
            val history = state.history.toMutableMap()
            confirmed.forEach { (id, fingerprint) -> history[id]?.let { history[id] = it.copy(acknowledged = fingerprint) } }
            try {
                commit(state.copy(history = history))
            } catch (e: IOException) {
                // Left pending, so the next pass offers these entries again.
            }
        }
    }

    override suspend fun persistRemoteChanges() {
        lock.withLock {
            val changes = LinkedHashMap(staged)
            staged.clear()
            if (changes.isNotEmpty()) apply(changes)
            val failed = unapplied
            unapplied = 0
            if (failed > 0) throw HistorySyncException.Unapplied(failed)
        }
    }

    fun beginPass() {
        unapplied = 0
    }

    /** Records local deletions, so they are sent to iCloud and a remote copy never comes back. */
    suspend fun recordDeletions(ids: Collection<String>) {
        lock.withLock {
            val state = current()
            val account = if (state.enabled) state.account else null
            val added = ids.mapNotNull(HistorySchema::canonicalId).distinct().filter { it !in state.deletions }
            if (added.isEmpty()) return
            added.forEach(offered::remove)
            val deletions = state.deletions + added.associateWith {
                HistoryDeletionIntent(it, newRevision(), account, cloudPending = account != null)
            }
            commit(state.copy(deletions = deletions))
        }
    }

    suspend fun pendingDeletions(account: String): List<PendingHistoryDeletion> = state().deletions.values
        .filter { it.cloudPending && it.account == account }
        .sortedBy { it.id }
        .map { PendingHistoryDeletion(it.id, account, it.revision) }

    /** Marks a deletion sent, unless it was requeued meanwhile. */
    suspend fun acknowledgeDeletion(attempt: PendingHistoryDeletion) {
        updateState { state ->
            val intent = state.deletions[attempt.id]
            if (intent == null || intent.revision != attempt.revision || intent.account != attempt.account) {
                state
            } else {
                state.copy(deletions = state.deletions + (attempt.id to intent.copy(cloudPending = false)))
            }
        }
    }

    suspend fun synchronizeDeletions(account: String, transport: HistorySyncTransport, admitted: suspend () -> Unit) {
        for (attempt in pendingDeletions(account)) {
            admitted()
            transport.delete(attempt.id)
            admitted()
            acknowledgeDeletion(attempt)
        }
    }

    private suspend fun apply(changes: Map<String, SyncableHistoryEntry?>) {
        val deleted = current().deletions.keys
        val outcomes = try {
            entries.update { list -> applied(list, changes.filterKeys { it !in deleted }) }
        } catch (e: IOException) {
            // Nothing was saved, so the cursor stays before these changes and the next pass replays them.
            unapplied += changes.size
            return
        }
        val state = current()
        val history = state.history.toMutableMap()
        outcomes.forEach { (id, outcome) ->
            when (outcome) {
                is Outcome.Saved -> history[id] = HistoryEntrySyncState(outcome.fingerprint, outcome.fingerprint, outcome.updatedAtMs)
                Outcome.Removed -> history.remove(id)
                Outcome.Kept -> history[id] = history[id]?.copy(deletedElsewhere = true)
                    ?: HistoryEntrySyncState(null, "", 0, deletedElsewhere = true)
            }
        }
        try {
            commit(state.copy(history = history))
        } catch (e: IOException) {
            unapplied += outcomes.size
        }
    }

    private sealed interface Outcome {
        data class Saved(val fingerprint: String, val updatedAtMs: Long) : Outcome

        data object Removed : Outcome

        data object Kept : Outcome
    }

    private fun applied(
        list: List<HistoryEntry>,
        changes: Map<String, SyncableHistoryEntry?>,
    ): Pair<List<HistoryEntry>, Map<String, Outcome>> {
        val byId = LinkedHashMap<String, HistoryEntry>()
        val others = mutableListOf<HistoryEntry>()
        list.forEach { entry ->
            val id = HistorySchema.canonicalId(entry.id)
            if (id == null) others += entry else byId[id] = entry
        }
        val outcomes = linkedMapOf<String, Outcome>()
        changes.forEach { (id, remote) ->
            val existing = byId[id]
            if (remote != null) {
                val merged = HistorySyncProjection.merge(remote, existing)
                byId[id] = merged
                val fingerprint = HistorySyncProjection.fingerprint(HistorySyncProjection.entry(merged, remote.updatedAtMs))
                outcomes[id] = Outcome.Saved(fingerprint, remote.updatedAtMs)
            } else if (existing == null || HistorySyncProjection.isSyncedCopy(existing)) {
                byId.remove(id)
                outcomes[id] = Outcome.Removed
            } else {
                // Recorded on this device: kept, and no longer offered for upload.
                outcomes[id] = Outcome.Kept
            }
        }
        return (byId.values + others) to outcomes
    }

    private fun current(): HistorySyncState = loaded ?: stateFile.load().also { loaded = it }

    private fun commit(next: HistorySyncState): HistorySyncState {
        if (next != loaded) stateFile.save(next)
        loaded = next
        return next
    }
}
