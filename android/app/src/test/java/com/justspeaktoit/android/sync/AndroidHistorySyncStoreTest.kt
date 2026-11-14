package com.justspeaktoit.android.sync

import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryFile
import com.justspeaktoit.android.history.HistoryStatus
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

internal class MemoryFile : HistoryFile {
    var text: String? = null

    override fun read(): String? = text

    override fun write(text: String) {
        this.text = text
    }

    override fun delete() {
        text = null
    }
}

internal class MemoryEntries(var list: List<HistoryEntry> = emptyList()) : SyncHistoryEntries {
    var failWrites = false

    override suspend fun snapshot(): List<HistoryEntry> = list

    override suspend fun <T> update(transform: (List<HistoryEntry>) -> Pair<List<HistoryEntry>, T>): T {
        val (next, result) = transform(list)
        if (failWrites) throw IOException("disk full")
        list = next
        return result
    }
}

class AndroidHistorySyncStoreTest {
    private val id = "0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9"
    private val account = "_user"
    private var clock = 2_000_000L
    private var revisions = 0

    private fun local(text: String = "hello there", cleanedUp: Boolean = false) = HistoryEntry(
        id = id.lowercase(),
        createdAtMs = 1_000_000,
        mode = "OnDevice",
        model = null,
        status = HistoryStatus.Completed,
        text = text,
        cleanedUp = cleanedUp,
        audioPath = "/data/audio.m4a",
    )

    private fun remote(updatedAtMs: Long = 3_000_000, processed: String? = null) = SyncableHistoryEntry(
        id, 1_000_000, "from the mac", processed, "apple/local/dictation", 1.5, 3, "macos", updatedAtMs,
    )

    private fun store(entries: MemoryEntries, file: MemoryFile = MemoryFile()) = AndroidHistorySyncStore(
        entries,
        HistorySyncStateFile(file),
        now = { clock },
        newRevision = { "REV${++revisions}" },
    )

    private suspend fun AndroidHistorySyncStore.signIn() = updateState { it.copy(enabled = true, account = account) }

    @Test
    fun testPending_offersLocalEntriesWithoutAudioOrFailures() = runBlocking {
        val failed = local().copy(id = "11111111-2222-4333-8444-555555555555", status = HistoryStatus.Failed)
        val store = store(MemoryEntries(listOf(local(), failed)))
        val pending = store.pendingEntries()
        assertEquals(1, pending.size)
        val offered = pending.single()
        assertEquals(id, offered.id)
        assertEquals("hello there", offered.rawTranscription)
        assertNull(offered.postProcessedText)
        assertEquals("android/on-device", offered.model)
        assertEquals("android", offered.originPlatform)
        assertEquals(2, offered.wordCount)
        // An entry that predates sync keeps its creation time, so an existing remote copy wins.
        assertEquals(1_000_000L, offered.updatedAtMs)
    }

    @Test
    fun testAcknowledge_stopsOfferingUntilTheEntryChanges() = runBlocking {
        val entries = MemoryEntries(listOf(local()))
        val store = store(entries)
        store.pendingEntries()
        store.didAcknowledge(setOf(id))
        assertTrue(store.pendingEntries().isEmpty())
        entries.list = listOf(local(text = "Hello there.", cleanedUp = true).copy(rawText = "hello there"))
        val edited = store.pendingEntries().single()
        assertEquals("Hello there.", edited.postProcessedText)
        assertEquals("hello there", edited.rawTranscription)
        assertEquals(clock, edited.updatedAtMs)
    }

    @Test
    fun testRemoteEntry_isMergedKeepingLocalAudio() = runBlocking {
        val entries = MemoryEntries(listOf(local()))
        val store = store(entries)
        store.didReceiveRemoteEntry(remote(processed = "From the Mac."))
        store.persistRemoteChanges()
        val merged = entries.list.single()
        assertEquals("From the Mac.", merged.text)
        assertTrue(merged.cleanedUp)
        assertEquals("from the mac", merged.rawText)
        assertEquals("/data/audio.m4a", merged.audioPath)
        assertTrue(store.pendingEntries().isEmpty())
    }

    @Test
    fun testRemoteEntry_addsASyncedCopyWithItsOrigin() = runBlocking {
        val entries = MemoryEntries()
        val store = store(entries)
        store.didReceiveRemoteEntry(remote())
        store.persistRemoteChanges()
        val copy = entries.list.single()
        assertEquals(id.lowercase(), copy.id)
        assertEquals("macos", copy.originPlatform)
        assertEquals("from the mac", copy.text)
        assertNull(copy.audioPath)
        assertTrue(store.pendingEntries().isEmpty())
    }

    @Test
    fun testRemoteEntry_olderThanAPendingLocalEditIsIgnored() = runBlocking {
        val entries = MemoryEntries(listOf(local()))
        val store = store(entries)
        store.pendingEntries()
        store.didAcknowledge(setOf(id))
        entries.list = listOf(local(text = "edited here"))
        clock = 5_000_000
        store.pendingEntries()
        store.didReceiveRemoteEntry(remote(updatedAtMs = 3_000_000))
        store.persistRemoteChanges()
        assertEquals("edited here", entries.list.single().text)
    }

    @Test
    fun testRemoteTombstone_removesASyncedCopyButKeepsALocalRecording() = runBlocking {
        val copyId = "11111111-2222-4333-8444-555555555555"
        val copy = local().copy(id = copyId, audioPath = null, originPlatform = "windows")
        val entries = MemoryEntries(listOf(local(), copy))
        val store = store(entries)
        store.didDeleteRemoteEntry(id)
        store.didDeleteRemoteEntry(copyId)
        store.persistRemoteChanges()
        assertEquals(listOf(id.lowercase()), entries.list.map { it.id })
        // Deleted elsewhere, so it is never uploaded again.
        assertTrue(store.pendingEntries().isEmpty())
        assertTrue(store.state().history.getValue(id).deletedElsewhere)
    }

    @Test
    fun testDeletionTicket_isSentOnceAndBlocksRemoteCopies() = runBlocking {
        val entries = MemoryEntries(listOf(local()))
        val store = store(entries)
        store.signIn()
        store.recordDeletions(listOf(id.lowercase()))
        entries.list = emptyList()
        val pending = store.pendingDeletions(account)
        assertEquals(listOf(PendingHistoryDeletion(id, account, "REV1")), pending)

        store.acknowledgeDeletion(pending.single())
        assertTrue(store.pendingDeletions(account).isEmpty())

        // Another device uploads it again: the deletion is requeued, not the entry restored.
        store.didReceiveRemoteEntry(remote())
        store.persistRemoteChanges()
        assertTrue(entries.list.isEmpty())
        assertEquals(listOf(PendingHistoryDeletion(id, account, "REV2")), store.pendingDeletions(account))
    }

    @Test
    fun testDeletionTicket_acknowledgementOfAStaleRevisionIsIgnored() = runBlocking {
        val store = store(MemoryEntries())
        store.signIn()
        store.recordDeletions(listOf(id))
        val stale = store.pendingDeletions(account).single().copy(revision = "OLD")
        store.acknowledgeDeletion(stale)
        assertEquals(1, store.pendingDeletions(account).size)
    }

    @Test
    fun testDeletionTicket_whileSignedOutIsNotSent() = runBlocking {
        val store = store(MemoryEntries())
        store.recordDeletions(listOf(id))
        assertTrue(store.pendingDeletions(account).isEmpty())
        assertFalse(store.state().deletions.getValue(id).cloudPending)
    }

    @Test
    fun testUnsavedRemoteChanges_areReportedSoTheCursorStays() = runBlocking {
        val entries = MemoryEntries().apply { failWrites = true }
        val store = store(entries)
        store.didReceiveRemoteEntry(remote())
        try {
            store.persistRemoteChanges()
            throw AssertionError("expected Unapplied")
        } catch (e: HistorySyncException.Unapplied) {
            assertEquals(1, e.count)
        }
    }

    @Test
    fun testState_survivesAReload() = runBlocking {
        val file = MemoryFile()
        val first = store(MemoryEntries(), file)
        first.signIn()
        first.saveCursor("cursor-1")
        first.recordDeletions(listOf(id))
        val reloaded = store(MemoryEntries(), file).state()
        assertEquals("cursor-1", reloaded.cursor)
        assertEquals(account, reloaded.account)
        assertTrue(reloaded.deletions.getValue(id).cloudPending)
        assertEquals(reloaded, HistorySyncStateCodec.decode(HistorySyncStateCodec.encode(reloaded)))
    }

    @Test
    fun testFingerprint_matchesTheDesktopAlgorithm() {
        // FNV-1a 64 of "a" is af63dc4c8601ec8c; the projection hashes the joined fields the same way.
        val entry = SyncableHistoryEntry(id, 1, null, null, "m", 0.0, 0, "android", 1)
        val joined = listOf(id, "1", "-", "-", "m", "0", "0", "android").joinToString("\u001F")
        assertEquals(fnv1a(joined), HistorySyncProjection.fingerprint(entry))
        assertEquals("af63dc4c8601ec8c", fnv1a("a"))
    }

    private fun fnv1a(text: String): String {
        var hash = -0x340d631b7bdddcdbL
        text.toByteArray(Charsets.UTF_8).forEach { hash = (hash xor (it.toLong() and 0xFF)) * 0x100000001b3L }
        return java.lang.Long.toUnsignedString(hash, 16)
    }
}
