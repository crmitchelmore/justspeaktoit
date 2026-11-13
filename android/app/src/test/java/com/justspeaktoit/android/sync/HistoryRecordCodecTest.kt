package com.justspeaktoit.android.sync

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HistoryRecordCodecTest {
    private val id = "0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9"

    private fun entry(
        raw: String? = "hello world",
        processed: String? = "Hello, world.",
        updatedAtMs: Long = 1_700_000_100_000,
    ) = SyncableHistoryEntry(id, 1_700_000_000_000, raw, processed, "openai/gpt-4o-transcribe", 2.5, 2, "macos", updatedAtMs)

    /** A record as CloudKit Web Services returns it, with the desktop schema's field types. */
    private fun recordJson(type: String? = HistorySchema.RECORD_TYPE): JSONObject {
        fun field(value: Any, type: String) = JSONObject().put("value", value).put("type", type)
        val fields = JSONObject()
            .put("entryID", field(id.lowercase(), "STRING"))
            .put("createdAt", field(1_700_000_000_000, "TIMESTAMP"))
            .put("rawTranscription", field("hello world", "STRING"))
            .put("postProcessedText", field("Hello, world.", "STRING"))
            .put("model", field("openai/gpt-4o-transcribe", "STRING"))
            .put("duration", field(2.5, "DOUBLE"))
            .put("wordCount", field(2, "INT64"))
            .put("originPlatform", field("macos", "STRING"))
            .put("updatedAt", field(1_700_000_100_000, "TIMESTAMP"))
        val o = JSONObject().put("recordName", id).put("recordChangeTag", "tag1").put("fields", fields)
        type?.let { o.put("recordType", it) }
        return o
    }

    @Test
    fun testDecode_readsTheDesktopSchema() {
        val change = HistoryRecordCodec.change(CloudKitWire.record(recordJson()))
        assertEquals(HistoryRemoteChange.Changed(entry()), change)
    }

    @Test
    fun testDecode_appliesTheSharedDefaultsForMissingFields() {
        val fields = JSONObject()
            .put("entryID", JSONObject().put("value", id).put("type", "STRING"))
            .put("createdAt", JSONObject().put("value", 1_000).put("type", "TIMESTAMP"))
        val record = CloudKitWire.record(
            JSONObject().put("recordName", id).put("recordType", HistorySchema.RECORD_TYPE).put("fields", fields),
        )
        val decoded = HistoryRecordCodec.entry(record)!!
        assertEquals("unknown", decoded.model)
        assertEquals("unknown", decoded.originPlatform)
        assertEquals(0.0, decoded.duration, 0.0)
        assertEquals(0, decoded.wordCount)
        assertEquals(1_000L, decoded.updatedAtMs)
        assertNull(decoded.rawTranscription)
    }

    @Test
    fun testDecode_ignoresOtherRecordTypesAndRecordsWithoutAnEntryId() {
        assertNull(HistoryRecordCodec.change(CloudKitWire.record(recordJson(type = "CompareRound"))))
        val noId = recordJson().also { it.getJSONObject("fields").remove("entryID") }
        assertNull(HistoryRecordCodec.change(CloudKitWire.record(noId)))
    }

    @Test
    fun testTombstone_isAcceptedByTypeOrByUuidName() {
        assertEquals(HistoryRemoteChange.Deleted(id), HistoryRecordCodec.deletion(id.lowercase(), null))
        assertEquals(HistoryRemoteChange.Deleted(id), HistoryRecordCodec.deletion(id, HistorySchema.RECORD_TYPE))
        assertNull(HistoryRecordCodec.deletion(id, "CompareRound"))
        assertNull(HistoryRecordCodec.deletion("not-a-uuid", null))
    }

    @Test
    fun testCreate_omitsEmptyFieldsAndEncodesTypedValues() {
        val op = HistoryRecordCodec.create(entry(processed = null))
        assertEquals(RecordOperation.CREATE, op.type)
        assertEquals(HistorySchema.RECORD_TYPE, op.recordType)
        assertFalse(op.fields!!.containsKey(HistorySchema.POST_PROCESSED_TEXT))
        val json = CloudKitWire.operation(op).getJSONObject("record").getJSONObject("fields")
        assertEquals("TIMESTAMP", json.getJSONObject("createdAt").getString("type"))
        assertEquals(1_700_000_000_000L, json.getJSONObject("createdAt").getLong("value"))
        assertEquals("DOUBLE", json.getJSONObject("duration").getString("type"))
        assertEquals("INT64", json.getJSONObject("wordCount").getString("type"))
    }

    @Test
    fun testUpdate_clearsOnlyFieldsTheServerHolds() {
        val existing = CloudKitWire.record(recordJson().also { it.getJSONObject("fields").remove("rawTranscription") })
        val op = HistoryRecordCodec.update(existing, entry(raw = null, processed = null))
        assertEquals(RecordOperation.UPDATE, op.type)
        assertEquals("tag1", op.recordChangeTag)
        val fields = op.fields!!
        assertTrue(fields.containsKey(HistorySchema.POST_PROCESSED_TEXT))
        assertNull(fields[HistorySchema.POST_PROCESSED_TEXT])
        assertFalse(fields.containsKey(HistorySchema.RAW_TRANSCRIPTION))
        val encoded = CloudKitWire.operation(op).getJSONObject("record").getJSONObject("fields")
        assertTrue(encoded.getJSONObject("postProcessedText").isNull("value"))
    }

    @Test(expected = CloudKitException.InvalidResponse::class)
    fun testUpdate_requiresAChangeTag() {
        val existing = CloudKitWire.record(recordJson().also { it.remove("recordChangeTag") })
        HistoryRecordCodec.update(existing, entry())
    }

    @Test(expected = CloudKitException.Encoding::class)
    fun testCreate_rejectsANonFiniteDuration() {
        HistoryRecordCodec.create(entry().copy(duration = Double.NaN))
    }

    @Test
    fun testForceDelete_sendsNoFields() {
        val json = CloudKitWire.operation(HistoryRecordCodec.forceDelete(id))
        assertEquals("forceDelete", json.getString("operationType"))
        assertFalse(json.getJSONObject("record").has("fields"))
    }

    @Test
    fun testConflictPolicy_remoteWinsWhenNewerOrEqual() {
        assertTrue(HistoryConflictPolicy.remoteWins(entry(updatedAtMs = 5), entry(updatedAtMs = 5)))
        assertFalse(HistoryConflictPolicy.remoteWins(entry(updatedAtMs = 4), entry(updatedAtMs = 5)))
    }

    @Test
    fun testReconciler_keepsTheLastChangePerEntryInArrivalOrder() {
        val other = "11111111-2222-4333-8444-555555555555"
        val changes = listOf(
            HistoryRemoteChange.Changed(entry()),
            HistoryRemoteChange.Changed(entry().copy(id = other)),
            HistoryRemoteChange.Deleted(id),
        )
        assertEquals(
            listOf(HistoryRemoteChange.Changed(entry().copy(id = other)), HistoryRemoteChange.Deleted(id)),
            HistoryChangeReconciler.coalesced(changes),
        )
    }

    @Test
    fun testRecordResults_separatesRecordErrors() {
        val results = CloudKitWire.recordResults(
            JSONArray().put(recordJson()).put(JSONObject().put("recordName", id).put("serverErrorCode", "NOT_FOUND")),
        )
        assertTrue(results[0] is RecordResult.Found)
        assertEquals(CloudKitServerError.NOT_FOUND, (results[1] as RecordResult.Failed).error.code)
    }
}
