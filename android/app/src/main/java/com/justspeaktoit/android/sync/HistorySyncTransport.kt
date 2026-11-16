package com.justspeaktoit.android.sync

/** What an upload did: entries now on the server, newer remote copies to apply and failures. */
data class HistoryUploadResult(
    val acknowledgedIds: Set<String>,
    val remoteEntries: List<SyncableHistoryEntry>,
    val failures: Map<String, Exception>,
)

/** One page of History changes and the cursor after it. */
data class HistoryChangePage(val changes: List<HistoryRemoteChange>, val syncToken: String?, val moreComing: Boolean)

/** The network side of History sync, so the coordinator can be tested without CloudKit. */
interface HistorySyncTransport {
    suspend fun fetchChanges(after: String?): HistoryChangePage

    suspend fun upload(entries: List<SyncableHistoryEntry>): HistoryUploadResult

    suspend fun delete(id: String)
}

/**
 * History over CloudKit Web Services, as Sources/SpeakSync/CloudKitWebSyncTransports.swift does it.
 * Every request is pinned to [session], so a pass stops rather than writing into another sign-in.
 */
class CloudKitHistorySyncTransport(
    private val client: CloudKitWebClient,
    private val session: Long,
) : HistorySyncTransport {
    override suspend fun fetchChanges(after: String?): HistoryChangePage {
        val page = client.fetchZoneChanges(HistorySchema.ZONE, after, session)
        val changes = mutableListOf<HistoryRemoteChange>()
        for (result in page.records) {
            when (result) {
                // As with a native per-record fetch error, the page is not consumed.
                is RecordResult.Failed -> throw CloudKitException.Server(result.error)
                is RecordResult.Found -> {
                    val record = result.record
                    val change = if (record.deleted) {
                        HistoryRecordCodec.deletion(record.recordName, record.recordType)
                    } else {
                        HistoryRecordCodec.change(record)
                    }
                    change?.let(changes::add)
                }
            }
        }
        return HistoryChangePage(changes, page.syncToken, page.moreComing)
    }

    override suspend fun upload(entries: List<SyncableHistoryEntry>): HistoryUploadResult {
        val acknowledged = mutableSetOf<String>()
        val remote = mutableListOf<SyncableHistoryEntry>()
        val failures = mutableMapOf<String, Exception>()
        val existing = try {
            CloudKitRecordBatch.lookup(entries.map { it.id }, client, session)
        } catch (e: CloudKitException) {
            return HistoryUploadResult(emptySet(), emptyList(), entries.associate { it.id to e })
        }
        val writes = mutableListOf<RecordOperation>()
        for (entry in entries) {
            try {
                when (val found = existing[entry.id] ?: LookupOutcome.Failed(CloudKitRecordBatch.missingResult())) {
                    is LookupOutcome.Failed -> throw found.error
                    LookupOutcome.Absent -> writes += HistoryRecordCodec.create(entry)
                    is LookupOutcome.Found -> {
                        // Resolved by record ID before saving, so a retry against an already present
                        // record is an acknowledgement, not a conflict.
                        val current = HistoryRecordCodec.entry(found.record)
                        if (current != null && HistoryConflictPolicy.remoteWins(current, entry)) {
                            acknowledged += entry.id
                            remote += current
                        } else {
                            writes += HistoryRecordCodec.update(found.record, entry)
                        }
                    }
                }
            } catch (e: CloudKitException) {
                failures[entry.id] = e
            }
        }
        CloudKitRecordBatch.modify(writes, client, session).forEach { (id, error) ->
            if (error == null) acknowledged += id else failures[id] = error
        }
        return HistoryUploadResult(acknowledged, remote, failures)
    }

    override suspend fun delete(id: String) {
        val error = CloudKitRecordBatch.modify(listOf(HistoryRecordCodec.forceDelete(id)), client, session)[id]
        if (error != null) throw error
    }
}

internal sealed interface LookupOutcome {
    data class Found(val record: CloudKitRecord) : LookupOutcome

    data object Absent : LookupOutcome

    data class Failed(val error: CloudKitException) : LookupOutcome
}

/**
 * Batched lookups and writes (Sources/SpeakSync/CloudKitWebRecordBatch.swift). Results are matched to
 * records by name, or by position when an error omits the name; a whole-request failure fails
 * every write in its chunk.
 */
internal object CloudKitRecordBatch {
    const val MAX_OPERATIONS = 200

    fun missingResult() = CloudKitException.InvalidResponse("CloudKit returned no result for a record.")

    suspend fun lookup(names: List<String>, client: CloudKitWebClient, session: Long): Map<String, LookupOutcome> {
        val outcomes = mutableMapOf<String, LookupOutcome>()
        for (chunk in names.chunked(MAX_OPERATIONS)) {
            val attributed = attribute(client.lookup(chunk, HistorySchema.ZONE, session), chunk)
            for (name in chunk) {
                outcomes[name] = when (val result = attributed[name]) {
                    null -> LookupOutcome.Failed(missingResult())
                    is RecordResult.Found ->
                        if (result.record.deleted) LookupOutcome.Absent else LookupOutcome.Found(result.record)
                    is RecordResult.Failed ->
                        if (result.error.code == CloudKitServerError.NOT_FOUND) {
                            LookupOutcome.Absent
                        } else {
                            LookupOutcome.Failed(CloudKitException.Server(result.error))
                        }
                }
            }
        }
        return outcomes
    }

    /** Each record's error, or null when it was written. A deleted record that was not found counts as written. */
    suspend fun modify(
        operations: List<RecordOperation>,
        client: CloudKitWebClient,
        session: Long,
    ): Map<String, CloudKitException?> {
        val outcomes = linkedMapOf<String, CloudKitException?>()
        for (chunk in operations.chunked(MAX_OPERATIONS)) {
            val results = try {
                client.modify(chunk, HistorySchema.ZONE, session)
            } catch (e: CloudKitException) {
                chunk.forEach { outcomes[it.recordName] = e }
                continue
            }
            val attributed = attribute(results, chunk.map { it.recordName })
            for (operation in chunk) {
                outcomes[operation.recordName] = when (val result = attributed[operation.recordName]) {
                    null -> missingResult()
                    is RecordResult.Found -> null
                    is RecordResult.Failed ->
                        if (operation.type == RecordOperation.FORCE_DELETE && result.error.code == CloudKitServerError.NOT_FOUND) {
                            null
                        } else {
                            CloudKitException.Server(result.error)
                        }
                }
            }
        }
        return outcomes
    }

    fun attribute(results: List<RecordResult>, names: List<String>): Map<String, RecordResult> {
        val requested = names.toSet()
        val attributed = mutableMapOf<String, RecordResult>()
        results.forEachIndexed { index, result ->
            val name = result.recordName ?: names.getOrNull(index)
            if (name != null && name in requested) attributed[name] = result
        }
        return attributed
    }
}
