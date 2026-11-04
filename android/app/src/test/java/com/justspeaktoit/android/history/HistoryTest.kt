package com.justspeaktoit.android.history

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HistoryTest {
    private val day = 24L * 60 * 60 * 1000
    private val now = 100 * day

    private fun entry(id: String, ageDays: Long, status: HistoryStatus = HistoryStatus.Completed) = HistoryEntry(
        id = id,
        createdAtMs = now - ageDays * day,
        mode = "OnDevice",
        model = null,
        status = status,
        text = "text $id",
    )

    private class MemoryFile(var text: String? = null) : HistoryFile {
        var writes = 0
        var failWrites = false
        override fun read() = text
        override fun write(text: String) {
            if (failWrites) throw java.io.IOException("disk full")
            writes++
            this.text = text
        }
        override fun delete() {
            text = null
        }
    }

    @Test
    fun testCodec_roundTripsAllFields() {
        val entries = listOf(
            HistoryEntry("a", 1, "Cloud", "openai/gpt-transcribe", HistoryStatus.Completed, "Hi \"there\"", null, true),
            HistoryEntry("b", 2, "SpeechService", null, HistoryStatus.Failed, "", "Network", false),
        )
        assertEquals(entries, HistoryCodec.decode(HistoryCodec.encode(entries)))
    }

    @Test
    fun testCodec_skipsUnreadableEntriesAndCorruptFiles() {
        val text = """{"version":1,"entries":[{"id":"ok","createdAtMs":5,"mode":"OnDevice","status":"Completed",""" +
            """"text":"kept"},{"id":"bad","status":"Nope"},{"id":3},null]}"""
        assertEquals(listOf("ok"), HistoryCodec.decode(text).map { it.id })
        assertTrue(HistoryCodec.decode("not json").isEmpty())
        assertTrue(HistoryCodec.decode("{}").isEmpty())
        assertNull(HistoryCodec.decode(text).single().model)
    }

    @Test
    fun testPrune_appliesRetentionNewestFirst() {
        val entries = listOf(entry("old", 40), entry("new", 1), entry("mid", 10))
        assertEquals(listOf("new", "mid", "old"), HistoryPolicy.prune(entries, now, Retention.Forever).map { it.id })
        assertEquals(listOf("new", "mid"), HistoryPolicy.prune(entries, now, Retention.Month).map { it.id })
        assertEquals(listOf("new"), HistoryPolicy.prune(entries, now, Retention.Week).map { it.id })
        assertTrue(HistoryPolicy.prune(entries, now, Retention.Off).isEmpty())
    }

    @Test
    fun testPrune_capsEntryCount() {
        val many = (0 until HistoryPolicy.MAX_ENTRIES + 20).map { entry("e$it", 0).copy(createdAtMs = now - it) }
        val kept = HistoryPolicy.prune(many, now, Retention.Forever)
        assertEquals(HistoryPolicy.MAX_ENTRIES, kept.size)
        assertEquals("e0", kept.first().id)
    }

    @Test
    fun testStore_loadRewritesOnlyWhenPruned() {
        val fresh = MemoryFile(HistoryCodec.encode(listOf(entry("a", 1))))
        HistoryStore(fresh) { now }.load(Retention.Month)
        assertEquals(0, fresh.writes)

        val stale = MemoryFile(HistoryCodec.encode(listOf(entry("a", 1), entry("old", 60))))
        val kept = HistoryStore(stale) { now }.load(Retention.Month)
        assertEquals(listOf("a"), kept.map { it.id })
        assertEquals(listOf("a"), HistoryCodec.decode(stale.text!!).map { it.id })
    }

    @Test
    fun testStore_addRemoveClearPersist() {
        val file = MemoryFile()
        val store = HistoryStore(file) { now }
        store.add(entry("a", 0), Retention.Month)
        store.add(entry("b", 0, HistoryStatus.Failed).copy(createdAtMs = now + 1), Retention.Month)
        assertEquals(listOf("b", "a"), HistoryCodec.decode(file.text!!).map { it.id })
        assertEquals(listOf("b"), store.remove("a", Retention.Month).map { it.id })
        assertTrue(store.clear().isEmpty())
        assertNull(file.text)
    }

    @Test
    fun testStore_unreadableBytesAreDeleted() {
        val file = MemoryFile("""{"entries":[{"text":"secret but unreadable"}]}""")
        assertTrue(HistoryStore(file) { now }.load(Retention.Month).isEmpty())
        assertNull(file.text)
    }

    @Test
    fun testStore_failedWriteKeepsEntryForNextWrite() {
        val file = MemoryFile()
        val store = HistoryStore(file) { now }
        file.failWrites = true
        assertThrows(java.io.IOException::class.java) { store.add(entry("a", 0), Retention.Month) }
        assertEquals(listOf("a"), store.cached.map { it.id })
        file.failWrites = false
        store.add(entry("b", 0).copy(createdAtMs = now + 1), Retention.Month)
        assertEquals(listOf("b", "a"), HistoryCodec.decode(file.text!!).map { it.id })
    }

    @Test
    fun testStore_removeAndReplaceApplyRetention() {
        var clock = now
        val file = MemoryFile()
        val store = HistoryStore(file) { clock }
        store.add(entry("a", 0), Retention.Week)
        store.add(entry("b", 0).copy(createdAtMs = now + 1), Retention.Week)
        clock = now + 8 * day
        store.add(entry("c", 0).copy(createdAtMs = clock), Retention.Week)
        assertEquals(listOf("c"), store.remove("missing", Retention.Week).map { it.id })
        val updated = entry("c", 0).copy(createdAtMs = clock, text = "Clean.", cleanedUp = true)
        val cleaned = store.replace(updated, Retention.Week)
        assertEquals("Clean.", cleaned.single().text)
        assertEquals(cleaned, store.replace(entry("gone", 0), Retention.Week))
    }

    @Test
    fun testStore_retentionOffSavesNothingAndDeletesExisting() {
        val file = MemoryFile(HistoryCodec.encode(listOf(entry("a", 1))))
        val store = HistoryStore(file) { now }
        assertTrue(store.load(Retention.Off).isEmpty())
        assertNull(file.text)
        assertTrue(store.add(entry("b", 0), Retention.Off).isEmpty())
        assertNull(file.text)
    }
}
