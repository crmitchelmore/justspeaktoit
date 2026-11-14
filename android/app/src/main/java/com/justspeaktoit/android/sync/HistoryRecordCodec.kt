package com.justspeaktoit.android.sync

import java.util.Locale

/**
 * One History entry as every platform syncs it: the `TranscriptionHistory` record in
 * `TranscriptionHistoryZone` (Sources/SpeakSync/SyncSchema.swift). Audio is never part of it.
 * [id] is the canonical upper-case UUID, which is also the record name.
 */
data class SyncableHistoryEntry(
    val id: String,
    val createdAtMs: Long,
    val rawTranscription: String?,
    val postProcessedText: String?,
    val model: String,
    val duration: Double,
    val wordCount: Int,
    val originPlatform: String,
    val updatedAtMs: Long,
)

/** One change from the zone's change feed. */
sealed interface HistoryRemoteChange {
    val id: String

    data class Changed(val entry: SyncableHistoryEntry) : HistoryRemoteChange {
        override val id: String get() = entry.id
    }

    /** A tombstone: the entry was deleted on another device. */
    data class Deleted(override val id: String) : HistoryRemoteChange
}

object HistorySchema {
    const val ZONE = "TranscriptionHistoryZone"
    const val RECORD_TYPE = "TranscriptionHistory"
    const val BATCH_SIZE = 100

    const val ENTRY_ID = "entryID"
    const val CREATED_AT = "createdAt"
    const val RAW_TRANSCRIPTION = "rawTranscription"
    const val POST_PROCESSED_TEXT = "postProcessedText"
    const val MODEL = "model"
    const val DURATION = "duration"
    const val WORD_COUNT = "wordCount"
    const val ORIGIN_PLATFORM = "originPlatform"
    const val UPDATED_AT = "updatedAt"

    private val uuid = Regex("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

    /** The canonical upper-case form of a UUID string, or null when [text] is not one. */
    fun canonicalId(text: String): String? = if (uuid.matches(text)) text.uppercase(Locale.ROOT) else null
}

/** Reads and writes History records exactly as Sources/SpeakSync/SyncRecordCodecs.swift does. */
object HistoryRecordCodec {
    fun entry(record: CloudKitRecord): SyncableHistoryEntry? {
        val id = record.string(HistorySchema.ENTRY_ID)?.let(HistorySchema::canonicalId) ?: return null
        val createdAt = record.timestamp(HistorySchema.CREATED_AT) ?: return null
        return SyncableHistoryEntry(
            id = id,
            createdAtMs = createdAt,
            rawTranscription = record.string(HistorySchema.RAW_TRANSCRIPTION),
            postProcessedText = record.string(HistorySchema.POST_PROCESSED_TEXT),
            model = record.string(HistorySchema.MODEL) ?: "unknown",
            duration = record.double(HistorySchema.DURATION) ?: 0.0,
            wordCount = record.long(HistorySchema.WORD_COUNT)?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt() ?: 0,
            originPlatform = record.string(HistorySchema.ORIGIN_PLATFORM) ?: "unknown",
            updatedAtMs = record.timestamp(HistorySchema.UPDATED_AT) ?: createdAt,
        )
    }

    /** Every field, in schema order; a null value means the field is empty. */
    fun assignments(entry: SyncableHistoryEntry): List<Pair<String, FieldValue?>> = listOf(
        HistorySchema.ENTRY_ID to FieldValue.Text(entry.id),
        HistorySchema.CREATED_AT to FieldValue.Timestamp(entry.createdAtMs),
        HistorySchema.RAW_TRANSCRIPTION to entry.rawTranscription?.let { FieldValue.Text(it) },
        HistorySchema.POST_PROCESSED_TEXT to entry.postProcessedText?.let { FieldValue.Text(it) },
        HistorySchema.MODEL to FieldValue.Text(entry.model),
        HistorySchema.DURATION to FieldValue.Real(entry.duration),
        HistorySchema.WORD_COUNT to FieldValue.Int64(entry.wordCount.toLong()),
        HistorySchema.ORIGIN_PLATFORM to FieldValue.Text(entry.originPlatform),
        HistorySchema.UPDATED_AT to FieldValue.Timestamp(entry.updatedAtMs),
    )

    /** A History record from the change feed; records of other types in the zone are ignored. */
    fun change(record: CloudKitRecord): HistoryRemoteChange? {
        if (record.recordType != HistorySchema.RECORD_TYPE) return null
        return entry(record)?.let { HistoryRemoteChange.Changed(it) }
    }

    /** A tombstone for a History record. A tombstone without a type is accepted by its name. */
    fun deletion(recordName: String, recordType: String?): HistoryRemoteChange? {
        if (recordType != null && recordType != HistorySchema.RECORD_TYPE) return null
        return HistorySchema.canonicalId(recordName)?.let { HistoryRemoteChange.Deleted(it) }
    }

    /** A new record with only the fields that have values. */
    fun create(entry: SyncableHistoryEntry): RecordOperation {
        validate(entry)
        val fields = assignments(entry).filter { it.second != null }.toMap()
        return RecordOperation(RecordOperation.CREATE, entry.id, HistorySchema.RECORD_TYPE, null, fields)
    }

    /** An update to [existing]; a field is cleared only when the server holds a value for it. */
    fun update(existing: CloudKitRecord, entry: SyncableHistoryEntry): RecordOperation {
        val changeTag = existing.recordChangeTag
        if (changeTag.isNullOrEmpty()) throw CloudKitException.InvalidResponse("A fetched record had no change tag.")
        validate(entry)
        val fields = linkedMapOf<String, FieldValue?>()
        assignments(entry).forEach { (key, value) ->
            if (value != null || existing.hasValue(key)) fields[key] = value
        }
        return RecordOperation(
            RecordOperation.UPDATE,
            existing.recordName,
            existing.recordType ?: HistorySchema.RECORD_TYPE,
            changeTag,
            fields,
        )
    }

    fun forceDelete(id: String): RecordOperation = RecordOperation(RecordOperation.FORCE_DELETE, id, null, null, null)

    private fun validate(entry: SyncableHistoryEntry) {
        if (!entry.duration.isFinite()) throw CloudKitException.Encoding()
    }
}

/** A newer or equal remote copy wins, so a retry against an already present record is an acknowledgement. */
object HistoryConflictPolicy {
    fun remoteWins(remote: SyncableHistoryEntry, local: SyncableHistoryEntry): Boolean =
        remote.updatedAtMs >= local.updatedAtMs
}

/** Keeps the last change per entry, in the order those last changes arrived. */
object HistoryChangeReconciler {
    fun coalesced(changes: List<HistoryRemoteChange>): List<HistoryRemoteChange> {
        val last = linkedMapOf<String, IndexedValue<HistoryRemoteChange>>()
        changes.forEachIndexed { index, change -> last[change.id] = IndexedValue(index, change) }
        return last.values.sortedBy { it.index }.map { it.value }
    }
}
