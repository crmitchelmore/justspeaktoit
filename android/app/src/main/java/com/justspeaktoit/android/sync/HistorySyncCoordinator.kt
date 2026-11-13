package com.justspeaktoit.android.sync

/** The local side of History sync (Sources/SpeakSync/SyncModels.swift `HistorySyncStore`). */
interface HistorySyncLocalStore {
    suspend fun loadCursor(): String?

    suspend fun saveCursor(token: String)

    /** Entries the server has not acknowledged in their current form, oldest first. */
    suspend fun pendingEntries(): List<SyncableHistoryEntry>

    suspend fun didReceiveRemoteEntry(entry: SyncableHistoryEntry)

    suspend fun didDeleteRemoteEntry(id: String)

    suspend fun didAcknowledge(ids: Set<String>)

    /** Saves what the received changes did; throws when any of them could not be applied. */
    suspend fun persistRemoteChanges()
}

sealed class HistorySyncException(message: String) : Exception(message) {
    class InvalidChangePage : HistorySyncException("CloudKit returned a change page that does not advance.")

    class PartialUploadFailure(val count: Int) : HistorySyncException("$count History entries failed to upload.")

    class ReconciliationIncomplete(val count: Int) :
        HistorySyncException("History reconciliation left $count entries pending.")

    class Unapplied(val count: Int) : HistorySyncException("$count received History changes could not be applied.")
}

/**
 * One reconciliation pass, as Sources/SpeakSync/HistorySyncCoordinator.swift runs it: fetch and
 * apply every change page, then upload pending entries in batches until none remain.
 * [admitted] runs before every step and throws when the pass must stop (signed out or a new session).
 */
class HistorySyncCoordinator(
    private val transport: HistorySyncTransport,
    private val store: HistorySyncLocalStore,
    private val admitted: suspend () -> Unit = {},
) {
    suspend fun runPass() {
        fetchRemoteChanges()
        admitted()
        uploadPendingEntries()
        val remaining = store.pendingEntries().size
        if (remaining != 0) throw HistorySyncException.ReconciliationIncomplete(remaining)
    }

    private suspend fun fetchRemoteChanges() {
        admitted()
        var token = store.loadCursor()
        while (true) {
            admitted()
            val page = transport.fetchChanges(token)
            // Checked before anything is applied: a page that cannot advance the cursor would repeat forever.
            if (page.moreComing && (page.syncToken == null || page.syncToken == token)) {
                throw HistorySyncException.InvalidChangePage()
            }
            for (change in HistoryChangeReconciler.coalesced(page.changes)) {
                admitted()
                when (change) {
                    is HistoryRemoteChange.Changed -> store.didReceiveRemoteEntry(change.entry)
                    is HistoryRemoteChange.Deleted -> store.didDeleteRemoteEntry(change.id)
                }
            }
            store.persistRemoteChanges()
            page.syncToken?.let {
                admitted()
                store.saveCursor(it)
                token = it
            }
            if (!page.moreComing) break
        }
    }

    private suspend fun uploadPendingEntries() {
        while (true) {
            val pending = store.pendingEntries()
            if (pending.isEmpty()) return
            admitted()
            val result = transport.upload(pending.take(HistorySchema.BATCH_SIZE))
            admitted()
            result.remoteEntries.forEach { store.didReceiveRemoteEntry(it) }
            store.persistRemoteChanges()
            if (result.acknowledgedIds.isNotEmpty()) {
                admitted()
                store.didAcknowledge(result.acknowledgedIds)
            }
            val remaining = store.pendingEntries().size
            if (result.failures.isNotEmpty()) throw HistorySyncException.PartialUploadFailure(result.failures.size)
            if (remaining >= pending.size) throw HistorySyncException.ReconciliationIncomplete(remaining)
        }
    }
}
